import Dispatch
import Foundation
import Metal
import MetalFX
import OSLog
import QuartzCore

public struct DLSMDiagnostics: Equatable, Sendable {
    public let nativeTemporalFrames: UInt64
    public let reconstructedTemporalFrames: UInt64
    public let spatialFallbackFrames: UInt64
    public let lastFallbackReason: String?
}

/// Internal Metal/MetalFX implementation hidden behind `SolDLSMPipeline`.
final class DLSMProcessor: @unchecked Sendable {
    private struct Dimensions: Equatable {
        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int
        let pixelFormat: MTLPixelFormat
        let depthPixelFormat: MTLPixelFormat?
        let motionPixelFormat: MTLPixelFormat?
    }

    private struct CameraMetadata {
        let nearPlane: Float
        let farPlane: Float
        let fieldOfViewDegrees: Float
        let aspectRatio: Float
    }

    private enum TemporalInputSource: String, Sendable {
        case native
        case solModel = "sol-model"
        case experimentalReconstruction = "experimental-reconstruction"
    }

    private struct TemporalInputs {
        let depthTexture: any MTLTexture
        let motionTexture: any MTLTexture
        let reactiveMaskTexture: (any MTLTexture)?
        let motionVectorScaleX: Float
        let motionVectorScaleY: Float
        let jitterOffsetX: Float
        let jitterOffsetY: Float
        let depthReversed: Bool
        let deltaTimeSeconds: Float
        let camera: CameraMetadata?
        let source: TemporalInputSource
    }

    private enum TemporalInputValidation {
        case valid(TemporalInputs)
        case invalid(String)
    }

    private let lock = NSLock()
    private let telemetryLock = NSLock()
    private let temporalInFlightGate = DispatchSemaphore(value: 1)
    private let outputLayer: CAMetalLayer
    private let logger = Logger(subsystem: "com.solemu.app", category: "DLSM")
    private let temporalGPUTiming = DLSMGPUTimingAccumulator()
    private let allowsExperimentalTemporal: Bool
    private let solTemporalModel: SolTemporalModel?
    private let trainingCapture: DLSMTrainingCapture?

    private var configuration = DLSMConfiguration(
        mode: .off,
        quality: .quality,
        frameGeneration: false
    )
    private var acceptsFrames = false
    private var cachedCommandQueues: [UInt: any MTLCommandQueue] = [:]
    private var cachedTextures: [UInt: any MTLTexture] = [:]
    private var outputSize = CGSize.zero
    private var dimensions: Dimensions?
    private var spatialScaler: (any MTLFXSpatialScaler)?
    private var temporalScaler: (any MTLFXTemporalScaler)?
    private var temporalInputProvider: (any DLSMTemporalInputProvider)?
    private var temporalInputProviderSource: TemporalInputSource?
    private var frameInterpolatorObject: AnyObject?
    private var downsamplePipeline: (any MTLComputePipelineState)?
    private var downsampledColorTexture: (any MTLTexture)?
    private var currentUpscaledTexture: (any MTLTexture)?
    private var previousUpscaledTexture: (any MTLTexture)?
    private var resetMetalFXHistory = true
    private var hasUpscaledHistory = false
    private var lastFrameID: UInt64?
    private var nativeTemporalFrameCount: UInt64 = 0
    private var reconstructedTemporalFrameCount: UInt64 = 0
    private var spatialFallbackFrameCount: UInt64 = 0
    private var lastTemporalFallbackReason: String?
    private var didLogNativeTemporalAcceptance = false
    private var didLogReconstructedTemporalAcceptance = false
    private var didLogMissingCamera = false
    private var didLogCommandBufferFailure = false

    init(outputLayer: CAMetalLayer) {
        self.outputLayer = outputLayer
        self.allowsExperimentalTemporal =
            ProcessInfo.processInfo.environment[
                "SOL_DLSM_ALLOW_EXPERIMENTAL_TEMPORAL"
            ] == "1"
        self.solTemporalModel = SolTemporalModel.preferred()
        self.trainingCapture = DLSMTrainingCapture.fromEnvironment()
    }

    var isEnabled: Bool {
        lock.withLock {
            configuration.isEnabled
        }
    }

    var diagnostics: DLSMDiagnostics {
        lock.withLock {
            DLSMDiagnostics(
                nativeTemporalFrames: nativeTemporalFrameCount,
                reconstructedTemporalFrames: reconstructedTemporalFrameCount,
                spatialFallbackFrames: spatialFallbackFrameCount,
                lastFallbackReason: lastTemporalFallbackReason
            )
        }
    }

    func beginSession(captureGroup: String?) {
        lock.withLock {
            temporalInFlightGate.wait()
            defer { temporalInFlightGate.signal() }
            cachedCommandQueues.removeAll(keepingCapacity: true)
            cachedTextures.removeAll(keepingCapacity: true)
            acceptsFrames = true
            lastFrameID = nil
            resetMetalFXHistory = true
            hasUpscaledHistory = false
            temporalInputProvider?.resetHistory()
            trainingCapture?.beginSession(captureGroup: captureGroup)
        }
    }

    func endSession() {
        lock.withLock {
            acceptsFrames = false
            temporalInFlightGate.wait()
            defer { temporalInFlightGate.signal() }
            lastFrameID = nil
            cachedCommandQueues.removeAll(keepingCapacity: true)
            cachedTextures.removeAll(keepingCapacity: true)
            trainingCapture?.endSession()
            invalidatePipeline()
        }
    }

    func configure(_ configuration: DLSMConfiguration, outputSize: CGSize) {
        lock.withLock {
            let configurationChanged = self.configuration != configuration
            let outputSizeChanged = self.outputSize != outputSize
            guard configurationChanged || outputSizeChanged else {
                return
            }

            // A resize or mode change can replace the scaler and every
            // reconstruction texture. Wait until the last Temporal command
            // buffer has stopped using them before invalidating the pipeline.
            temporalInFlightGate.wait()
            defer { temporalInFlightGate.signal() }

            if configurationChanged {
                self.configuration = configuration
                lastFrameID = nil
                invalidatePipeline()
            }
            if outputSizeChanged {
                self.outputSize = outputSize
                lastFrameID = nil
                invalidatePipeline()
            }
        }
    }

    func present(frame: DLSMFrameInfoV2) -> Bool {
        lock.withLock {
            guard acceptsFrames,
                  configuration.isEnabled,
                  frame.flags.contains(.color),
                  frame.colorWidth > 0,
                  frame.colorHeight > 0,
                  outputSize.width >= 1,
                  outputSize.height >= 1,
                  let commandQueuePointer = frame.metalCommandQueue,
                  let colorTexturePointer = frame.colorTexture,
                  let commandQueue = commandQueue(at: commandQueuePointer),
                  let sourceTexture = texture(at: colorTexturePointer),
                  Int(frame.colorWidth) == sourceTexture.width,
                  Int(frame.colorHeight) == sourceTexture.height,
                  Self.declaredColorFormat(frame.colorFormat, matches: sourceTexture),
                  sourceTexture.usage.contains(.shaderRead),
                  commandQueue.device.registryID == sourceTexture.device.registryID,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return false
            }

            let temporalGate = configuration.mode == .temporal
                ? temporalInFlightGate
                : nil
            temporalGate?.wait()
            var didEnqueueTemporalWork = false
            defer {
                if temporalGate != nil, !didEnqueueTemporalWork {
                    temporalGate?.signal()
                }
            }

            let targetWidth = max(1, Int(outputSize.width.rounded()))
            let targetHeight = max(1, Int(outputSize.height.rounded()))
            let requestedInputWidth = max(
                1,
                Int((Double(targetWidth) * configuration.quality.renderScale).rounded())
            )
            let requestedInputHeight = max(
                1,
                Int((Double(targetHeight) * configuration.quality.renderScale).rounded())
            )
            let inputWidth = min(sourceTexture.width, requestedInputWidth)
            let inputHeight = min(sourceTexture.height, requestedInputHeight)

            let frameDiscontinuity = consumeDiscontinuity(for: frame)
            if frameDiscontinuity {
                resetMetalFXHistory = true
                hasUpscaledHistory = false
            }

            let nativeTemporalValidation: TemporalInputValidation?
            if configuration.mode == .temporal {
                nativeTemporalValidation = validateTemporalInputs(
                    frame: frame,
                    sourceTexture: sourceTexture,
                    expectedWidth: inputWidth,
                    expectedHeight: inputHeight
                )
            } else {
                nativeTemporalValidation = nil
            }

            let dimensions = Dimensions(
                inputWidth: inputWidth,
                inputHeight: inputHeight,
                outputWidth: targetWidth,
                outputHeight: targetHeight,
                pixelFormat: sourceTexture.pixelFormat,
                depthPixelFormat: configuration.mode == .temporal ? .r32Float : nil,
                motionPixelFormat: configuration.mode == .temporal ? .rg16Float : nil
            )

            guard ensurePipeline(for: dimensions, device: sourceTexture.device),
                  let inputTexture = encodeDLSMInput(
                    sourceTexture: sourceTexture,
                    commandBuffer: commandBuffer,
                    dimensions: dimensions
                  ) else {
                return false
            }

            trainingCapture?.encode(
                frameID: frame.frameID,
                presentationTimestampNanoseconds:
                    frame.presentationTimestampNanoseconds,
                texture: inputTexture,
                commandBuffer: commandBuffer,
                discontinuity: frameDiscontinuity
            )

            let temporalInputs: TemporalInputs?
            if configuration.mode == .temporal {
                switch nativeTemporalValidation {
                case let .valid(inputs):
                    temporalInputProvider?.resetHistory()
                    temporalInputs = inputs
                    recordNativeTemporalFrame()
                case let .invalid(nativeReason):
                    if let reconstructed = temporalInputProvider?.encode(
                        sourceTexture: inputTexture,
                        commandBuffer: commandBuffer,
                        resetHistory: frameDiscontinuity || resetMetalFXHistory
                    ) {
                        temporalInputs = TemporalInputs(
                            depthTexture: reconstructed.depthTexture,
                            motionTexture: reconstructed.motionTexture,
                            reactiveMaskTexture: reconstructed.reactiveMaskTexture,
                            motionVectorScaleX: 1,
                            motionVectorScaleY: 1,
                            jitterOffsetX: 0,
                            jitterOffsetY: 0,
                            depthReversed: false,
                            deltaTimeSeconds:
                                frame.deltaTimeSeconds.isFinite &&
                                frame.deltaTimeSeconds > 0
                                    ? frame.deltaTimeSeconds
                                    : 0,
                            camera: nil,
                            source:
                                temporalInputProviderSource ??
                                .experimentalReconstruction
                        )
                        recordReconstructedTemporalFrame(
                            nativeReason: nativeReason,
                            source:
                                temporalInputProviderSource ??
                                .experimentalReconstruction
                        )
                    } else {
                        temporalInputs = nil
                        recordTemporalFallback(
                            allowsExperimentalTemporal
                                ? "the experimental Sol motion provider failed"
                                : "no trained Sol model or validated native motion was available"
                        )
                        resetMetalFXHistory = true
                        hasUpscaledHistory = false
                    }
                case nil:
                    temporalInputs = nil
                }
            } else {
                temporalInputs = nil
            }

            commandBuffer.label = temporalInputs == nil
                ? "DLSM Spatial"
                : temporalInputs?.source == .native
                    ? "DLSM Native Temporal"
                    : temporalInputs?.source == .solModel
                        ? "DLSM Sol Model Temporal"
                        : "DLSM Experimental Temporal"
            installCompletionTelemetry(
                on: commandBuffer,
                source: temporalInputs?.source
            )

            if configuration.mode == .temporal,
               configuration.frameGeneration,
               let temporalInputs,
               let currentUpscaledTexture,
               let drawable = outputLayer.nextDrawable(),
               encodeTemporal(
                    sourceTexture: inputTexture,
                    outputTexture: currentUpscaledTexture,
                    commandBuffer: commandBuffer,
                    dimensions: dimensions,
                    inputs: temporalInputs
               ) {
                let didPresent = encodeFrameGeneratedPresentation(
                    commandQueue: commandQueue,
                    commandBuffer: commandBuffer,
                    currentTexture: currentUpscaledTexture,
                    firstDrawable: drawable,
                    dimensions: dimensions,
                    inputs: temporalInputs,
                    resetHistory: frameDiscontinuity,
                    completionGate: temporalGate
                )
                didEnqueueTemporalWork = didPresent
                return didPresent
            }

            guard let drawable = outputLayer.nextDrawable() else {
                return false
            }

            let encoded: Bool
            if configuration.mode == .temporal, let temporalInputs {
                encoded = encodeTemporal(
                    sourceTexture: inputTexture,
                    outputTexture: drawable.texture,
                    commandBuffer: commandBuffer,
                    dimensions: dimensions,
                    inputs: temporalInputs
                )
            } else {
                encoded = encodeSpatial(
                    sourceTexture: inputTexture,
                    outputTexture: drawable.texture,
                    commandBuffer: commandBuffer,
                    dimensions: dimensions
                )
            }

            guard encoded else {
                return false
            }

            if let temporalGate {
                commandBuffer.addCompletedHandler { _ in
                    temporalGate.signal()
                }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            didEnqueueTemporalWork = temporalGate != nil
            return true
        }
    }

    private func consumeDiscontinuity(for frame: DLSMFrameInfoV2) -> Bool {
        let explicitReset = frame.flags.contains(.discontinuity)
        let frameGap: Bool
        if let lastFrameID {
            frameGap = lastFrameID == UInt64.max || frame.frameID != lastFrameID + 1
        } else {
            frameGap = true
        }
        lastFrameID = frame.frameID
        return explicitReset || frameGap
    }

    private func validateTemporalInputs(
        frame: DLSMFrameInfoV2,
        sourceTexture: any MTLTexture,
        expectedWidth: Int,
        expectedHeight: Int
    ) -> TemporalInputValidation {
        guard sourceTexture.width == expectedWidth,
              sourceTexture.height == expectedHeight else {
            return .invalid(
                "the compatibility downsample path cannot preserve native attachment alignment"
            )
        }
        guard frame.declaresNativeTemporalInputs else {
            return .invalid("the renderer supplied final color without depth and motion")
        }
        guard let depthPointer = frame.depthTexture,
              let motionPointer = frame.motionTexture,
              let depthTexture = texture(at: depthPointer),
              let motionTexture = texture(at: motionPointer) else {
            return .invalid("the native attachment flags did not include valid Metal objects")
        }
        guard frame.depthFormat == .r32Float,
              depthTexture.pixelFormat == .r32Float else {
            return .invalid("depth must be canonical R32Float normalized device depth")
        }
        guard frame.motionFormat == .rg16Float,
              motionTexture.pixelFormat == .rg16Float else {
            return .invalid("motion must be canonical RG16Float current-to-previous displacement")
        }
        guard Int(frame.depthWidth) == expectedWidth,
              Int(frame.depthHeight) == expectedHeight,
              depthTexture.width == expectedWidth,
              depthTexture.height == expectedHeight,
              Int(frame.motionWidth) == expectedWidth,
              Int(frame.motionHeight) == expectedHeight,
              motionTexture.width == expectedWidth,
              motionTexture.height == expectedHeight else {
            return .invalid("depth and motion dimensions must match the DLSM input surface")
        }
        guard depthTexture.textureType == .type2D,
              motionTexture.textureType == .type2D,
              depthTexture.sampleCount == 1,
              motionTexture.sampleCount == 1,
              depthTexture.usage.contains(.shaderRead),
              motionTexture.usage.contains(.shaderRead) else {
            return .invalid("native attachments must be single-sample shader-readable 2D textures")
        }
        guard depthTexture.device.registryID == sourceTexture.device.registryID,
              motionTexture.device.registryID == sourceTexture.device.registryID else {
            return .invalid("all native attachments must belong to the presentation GPU")
        }
        guard frame.motionVectorScaleX.isFinite,
              frame.motionVectorScaleY.isFinite,
              frame.motionVectorScaleX != 0,
              frame.motionVectorScaleY != 0 else {
            return .invalid("motion-vector scale must be finite and nonzero")
        }

        let jitterX = frame.flags.contains(.jitter) ? frame.jitterOffsetX : 0
        let jitterY = frame.flags.contains(.jitter) ? frame.jitterOffsetY : 0
        guard jitterX.isFinite, jitterY.isFinite else {
            return .invalid("camera jitter must be finite")
        }

        let camera: CameraMetadata?
        if frame.hasValidCameraMetadata {
            camera = CameraMetadata(
                nearPlane: frame.nearPlane,
                farPlane: frame.farPlane,
                fieldOfViewDegrees: frame.fieldOfViewDegrees,
                aspectRatio: frame.aspectRatio
            )
        } else {
            camera = nil
        }

        let deltaTime = frame.deltaTimeSeconds.isFinite && frame.deltaTimeSeconds > 0
            ? frame.deltaTimeSeconds
            : 0

        return .valid(
            TemporalInputs(
                depthTexture: depthTexture,
                motionTexture: motionTexture,
                reactiveMaskTexture: nil,
                motionVectorScaleX: frame.motionVectorScaleX,
                motionVectorScaleY: frame.motionVectorScaleY,
                jitterOffsetX: jitterX,
                jitterOffsetY: jitterY,
                depthReversed: frame.flags.contains(.depthReversed),
                deltaTimeSeconds: deltaTime,
                camera: camera,
                source: .native
            )
        )
    }

    private func ensurePipeline(for dimensions: Dimensions, device: any MTLDevice) -> Bool {
        if self.dimensions == dimensions {
            return spatialScaler != nil &&
                downsamplePipeline != nil &&
                downsampledColorTexture != nil &&
                (dimensions.depthPixelFormat == nil || temporalScaler != nil)
        }

        invalidatePipeline()
        self.dimensions = dimensions

        let spatialDescriptor = MTLFXSpatialScalerDescriptor()
        spatialDescriptor.colorTextureFormat = dimensions.pixelFormat
        spatialDescriptor.outputTextureFormat = outputLayer.pixelFormat
        spatialDescriptor.inputWidth = dimensions.inputWidth
        spatialDescriptor.inputHeight = dimensions.inputHeight
        spatialDescriptor.outputWidth = dimensions.outputWidth
        spatialDescriptor.outputHeight = dimensions.outputHeight
        spatialDescriptor.colorProcessingMode = .perceptual
        spatialScaler = spatialDescriptor.makeSpatialScaler(device: device)

        guard spatialScaler != nil else {
            logger.error("MetalFX could not create the DLSM spatial scaler")
            return false
        }

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let downsampleFunction = library.makeFunction(name: "dlsmDownsample") else {
                logger.error("DLSM downsample function is missing")
                return false
            }
            downsamplePipeline = try device.makeComputePipelineState(
                function: downsampleFunction
            )
        } catch {
            logger.error("Could not compile the DLSM Metal kernel: \(error.localizedDescription)")
            return false
        }

        downsampledColorTexture = makeTexture(
            device: device,
            pixelFormat: dimensions.pixelFormat,
            width: dimensions.inputWidth,
            height: dimensions.inputHeight,
            usage: [.shaderRead, .shaderWrite]
        )

        guard downsamplePipeline != nil, downsampledColorTexture != nil else {
            logger.error("Metal could not create the DLSM input resources")
            return false
        }

        guard let depthPixelFormat = dimensions.depthPixelFormat,
              let motionPixelFormat = dimensions.motionPixelFormat else {
            temporalInputProvider = nil
            logger.info(
                "Configured spatial DLSM \(dimensions.inputWidth, privacy: .public)x\(dimensions.inputHeight, privacy: .public) -> \(dimensions.outputWidth, privacy: .public)x\(dimensions.outputHeight, privacy: .public)"
            )
            return true
        }

        if let solTemporalModel {
            temporalInputProvider = try? DLSMSolTemporalModelProvider(
                device: device,
                inputWidth: dimensions.inputWidth,
                inputHeight: dimensions.inputHeight,
                model: solTemporalModel
            )
            temporalInputProviderSource = temporalInputProvider == nil
                ? nil
                : .solModel
        } else if allowsExperimentalTemporal {
            temporalInputProvider = try? DLSMTemporalReconstructionProvider(
                device: device,
                inputWidth: dimensions.inputWidth,
                inputHeight: dimensions.inputHeight
            )
            temporalInputProviderSource = temporalInputProvider == nil
                ? nil
                : .experimentalReconstruction
        } else {
            temporalInputProvider = nil
            temporalInputProviderSource = nil
        }
        if temporalInputProvider == nil {
            logger.warning(
                "Temporal has no trained Sol model or validated native input provider; this frame will use Spatial"
            )
        } else {
            let source = temporalInputProviderSource?.rawValue ?? "unknown"
            logger.info(
                "DLSM provider \(self.temporalInputProvider?.identifier ?? "unknown", privacy: .public) is active as \(source, privacy: .public)"
            )
        }

        let temporalDescriptor = MTLFXTemporalScalerDescriptor()
        temporalDescriptor.colorTextureFormat = dimensions.pixelFormat
        temporalDescriptor.depthTextureFormat = depthPixelFormat
        temporalDescriptor.motionTextureFormat = motionPixelFormat
        temporalDescriptor.outputTextureFormat = outputLayer.pixelFormat
        temporalDescriptor.inputWidth = dimensions.inputWidth
        temporalDescriptor.inputHeight = dimensions.inputHeight
        temporalDescriptor.outputWidth = dimensions.outputWidth
        temporalDescriptor.outputHeight = dimensions.outputHeight
        temporalDescriptor.isAutoExposureEnabled = true
        temporalDescriptor.isReactiveMaskTextureEnabled = true
        temporalDescriptor.reactiveMaskTextureFormat = .r8Unorm
        temporalScaler = temporalDescriptor.makeTemporalScaler(device: device)

        guard temporalScaler != nil else {
            logger.error("MetalFX could not create the DLSM temporal scaler")
            return false
        }

        if configuration.frameGeneration {
            currentUpscaledTexture = makeTexture(
                device: device,
                pixelFormat: outputLayer.pixelFormat,
                width: dimensions.outputWidth,
                height: dimensions.outputHeight,
                usage: [.shaderRead, .shaderWrite, .renderTarget]
            )
            previousUpscaledTexture = makeTexture(
                device: device,
                pixelFormat: outputLayer.pixelFormat,
                width: dimensions.outputWidth,
                height: dimensions.outputHeight,
                usage: [.shaderRead, .shaderWrite, .renderTarget]
            )

            if #available(macOS 26.0, *), let temporalScaler {
                let descriptor = MTLFXFrameInterpolatorDescriptor()
                descriptor.scaler = temporalScaler
                descriptor.colorTextureFormat = outputLayer.pixelFormat
                descriptor.outputTextureFormat = outputLayer.pixelFormat
                descriptor.depthTextureFormat = depthPixelFormat
                descriptor.motionTextureFormat = motionPixelFormat
                descriptor.inputWidth = dimensions.inputWidth
                descriptor.inputHeight = dimensions.inputHeight
                descriptor.outputWidth = dimensions.outputWidth
                descriptor.outputHeight = dimensions.outputHeight
                frameInterpolatorObject = descriptor.makeFrameInterpolator(device: device)
            }
        }

        resetMetalFXHistory = true
        hasUpscaledHistory = false

        if configuration.frameGeneration, frameInterpolatorObject == nil {
            logger.warning(
                "Native temporal DLSM is active, but MetalFX frame interpolation could not be created"
            )
        } else {
            logger.info(
                "Configured temporal DLSM \(dimensions.inputWidth, privacy: .public)x\(dimensions.inputHeight, privacy: .public) -> \(dimensions.outputWidth, privacy: .public)x\(dimensions.outputHeight, privacy: .public)"
            )
        }
        return true
    }

    private func encodeDLSMInput(
        sourceTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        dimensions: Dimensions
    ) -> (any MTLTexture)? {
        guard sourceTexture.width != dimensions.inputWidth ||
              sourceTexture.height != dimensions.inputHeight else {
            return sourceTexture
        }
        guard let downsamplePipeline, let downsampledColorTexture,
              let compute = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        compute.label = "DLSM Low-Resolution Input"
        compute.setComputePipelineState(downsamplePipeline)
        compute.setTexture(sourceTexture, index: 0)
        compute.setTexture(downsampledColorTexture, index: 1)

        let threadWidth = downsamplePipeline.threadExecutionWidth
        let threadHeight = max(
            1,
            downsamplePipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        compute.dispatchThreads(
            MTLSize(
                width: dimensions.inputWidth,
                height: dimensions.inputHeight,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
        compute.endEncoding()
        return downsampledColorTexture
    }

    private func encodeFrameGeneratedPresentation(
        commandQueue: any MTLCommandQueue,
        commandBuffer: any MTLCommandBuffer,
        currentTexture: any MTLTexture,
        firstDrawable: any CAMetalDrawable,
        dimensions: Dimensions,
        inputs: TemporalInputs,
        resetHistory: Bool,
        completionGate: DispatchSemaphore?
    ) -> Bool {
        guard #available(macOS 26.0, *),
              let frameInterpolator = frameInterpolatorObject as? any MTLFXFrameInterpolator,
              let previousUpscaledTexture,
              let camera = inputs.camera,
              inputs.deltaTimeSeconds > 0 else {
            if inputs.camera == nil, !didLogMissingCamera {
                didLogMissingCamera = true
                logger.warning(
                    "Frame generation is waiting for native near/far plane, field-of-view, and aspect-ratio metadata"
                )
            }
            hasUpscaledHistory = true
            return encodeDirectPresentation(
                commandBuffer: commandBuffer,
                currentTexture: currentTexture,
                drawable: firstDrawable,
                updateHistory: true,
                completionGate: completionGate
            )
        }

        guard hasUpscaledHistory, !resetHistory else {
            hasUpscaledHistory = true
            return encodeDirectPresentation(
                commandBuffer: commandBuffer,
                currentTexture: currentTexture,
                drawable: firstDrawable,
                updateHistory: true,
                completionGate: completionGate
            )
        }

        guard let currentDrawable = outputLayer.nextDrawable(),
              let currentCommandBuffer = commandQueue.makeCommandBuffer() else {
            return encodeDirectPresentation(
                commandBuffer: commandBuffer,
                currentTexture: currentTexture,
                drawable: firstDrawable,
                updateHistory: true,
                completionGate: completionGate
            )
        }

        frameInterpolator.colorTexture = currentTexture
        frameInterpolator.prevColorTexture = previousUpscaledTexture
        frameInterpolator.depthTexture = inputs.depthTexture
        frameInterpolator.motionTexture = inputs.motionTexture
        frameInterpolator.outputTexture = firstDrawable.texture
        frameInterpolator.motionVectorScaleX = inputs.motionVectorScaleX
        frameInterpolator.motionVectorScaleY = inputs.motionVectorScaleY
        frameInterpolator.deltaTime = inputs.deltaTimeSeconds
        frameInterpolator.nearPlane = camera.nearPlane
        frameInterpolator.farPlane = camera.farPlane
        frameInterpolator.fieldOfView = camera.fieldOfViewDegrees
        frameInterpolator.aspectRatio = camera.aspectRatio
        frameInterpolator.jitterOffsetX = inputs.jitterOffsetX
        frameInterpolator.jitterOffsetY = inputs.jitterOffsetY
        frameInterpolator.isDepthReversed = inputs.depthReversed
        frameInterpolator.shouldResetHistory = false
        frameInterpolator.encode(commandBuffer: commandBuffer)

        guard encodeCopy(
            commandBuffer: commandBuffer,
            source: currentTexture,
            destinations: [previousUpscaledTexture]
        ) else {
            return false
        }
        currentCommandBuffer.label = "DLSM Generated Frame Pacing"
        guard encodeCopy(
            commandBuffer: currentCommandBuffer,
            source: currentTexture,
            destinations: [currentDrawable.texture]
        ) else {
            return false
        }
        if let completionGate {
            currentCommandBuffer.addCompletedHandler { _ in
                completionGate.signal()
            }
        }
        commandBuffer.present(firstDrawable)
        currentCommandBuffer.present(
            currentDrawable,
            afterMinimumDuration: Double(inputs.deltaTimeSeconds) / 2
        )
        commandBuffer.commit()
        currentCommandBuffer.commit()
        return true
    }

    private func encodeDirectPresentation(
        commandBuffer: any MTLCommandBuffer,
        currentTexture: any MTLTexture,
        drawable: any CAMetalDrawable,
        updateHistory: Bool,
        completionGate: DispatchSemaphore?
    ) -> Bool {
        var destinations: [any MTLTexture] = [drawable.texture]
        if updateHistory, let previousUpscaledTexture {
            destinations.append(previousUpscaledTexture)
        }
        guard encodeCopy(
            commandBuffer: commandBuffer,
            source: currentTexture,
            destinations: destinations
        ) else {
            return false
        }
        if let completionGate {
            commandBuffer.addCompletedHandler { _ in
                completionGate.signal()
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    private func encodeCopy(
        commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destinations: [any MTLTexture]
    ) -> Bool {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            return false
        }
        blit.label = "DLSM Present"
        let size = MTLSize(width: source.width, height: source.height, depth: 1)
        for destination in destinations {
            blit.copy(
                from: source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(),
                sourceSize: size,
                to: destination,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin()
            )
        }
        blit.endEncoding()
        return true
    }

    private func encodeSpatial(
        sourceTexture: any MTLTexture,
        outputTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        dimensions: Dimensions
    ) -> Bool {
        guard let spatialScaler else {
            return false
        }
        spatialScaler.colorTexture = sourceTexture
        spatialScaler.outputTexture = outputTexture
        spatialScaler.inputContentWidth = dimensions.inputWidth
        spatialScaler.inputContentHeight = dimensions.inputHeight
        spatialScaler.encode(commandBuffer: commandBuffer)
        return true
    }

    private func encodeTemporal(
        sourceTexture: any MTLTexture,
        outputTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        dimensions: Dimensions,
        inputs: TemporalInputs
    ) -> Bool {
        guard let temporalScaler else {
            return encodeSpatial(
                sourceTexture: sourceTexture,
                outputTexture: outputTexture,
                commandBuffer: commandBuffer,
                dimensions: dimensions
            )
        }

        temporalScaler.colorTexture = sourceTexture
        temporalScaler.depthTexture = inputs.depthTexture
        temporalScaler.motionTexture = inputs.motionTexture
        temporalScaler.reactiveMaskTexture = inputs.reactiveMaskTexture
        temporalScaler.outputTexture = outputTexture
        temporalScaler.inputContentWidth = dimensions.inputWidth
        temporalScaler.inputContentHeight = dimensions.inputHeight
        temporalScaler.motionVectorScaleX = inputs.motionVectorScaleX
        temporalScaler.motionVectorScaleY = inputs.motionVectorScaleY
        temporalScaler.jitterOffsetX = inputs.jitterOffsetX
        temporalScaler.jitterOffsetY = inputs.jitterOffsetY
        temporalScaler.preExposure = 1
        temporalScaler.isDepthReversed = inputs.depthReversed
        temporalScaler.reset = resetMetalFXHistory
        temporalScaler.encode(commandBuffer: commandBuffer)
        resetMetalFXHistory = false
        return true
    }

    private func makeTexture(
        device: any MTLDevice,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        usage: MTLTextureUsage
    ) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = usage
        return device.makeTexture(descriptor: descriptor)
    }

    private func recordNativeTemporalFrame() {
        nativeTemporalFrameCount += 1
        lastTemporalFallbackReason = nil
        if !didLogNativeTemporalAcceptance {
            didLogNativeTemporalAcceptance = true
            logger.info(
                "DLSM accepted native depth and motion attachments; temporal MetalFX is active"
            )
        }
    }

    private func recordReconstructedTemporalFrame(
        nativeReason: String,
        source: TemporalInputSource
    ) {
        reconstructedTemporalFrameCount += 1
        lastTemporalFallbackReason = nil
        if !didLogReconstructedTemporalAcceptance {
            didLogReconstructedTemporalAcceptance = true
            logger.info(
                "DLSM Temporal is active with \(source.rawValue, privacy: .public) provider \(self.temporalInputProvider?.identifier ?? "unknown", privacy: .public); native provider status: \(nativeReason, privacy: .public)"
            )
        }
    }

    private func recordTemporalFallback(_ reason: String) {
        spatialFallbackFrameCount += 1
        if lastTemporalFallbackReason != reason {
            logger.warning(
                "DLSM temporal input rejected: \(reason, privacy: .public). Falling back to spatial for this frame."
            )
        }
        lastTemporalFallbackReason = reason
    }

    private func installCompletionTelemetry(
        on commandBuffer: any MTLCommandBuffer,
        source: TemporalInputSource?
    ) {
        guard let source else {
            return
        }

        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            guard let self else {
                return
            }

            guard completedBuffer.status == .completed else {
                let reason =
                    completedBuffer.error?.localizedDescription ??
                    "Metal command buffer status \(completedBuffer.status.rawValue)"
                self.telemetryLock.withLock {
                    guard !self.didLogCommandBufferFailure else {
                        return
                    }
                    self.didLogCommandBufferFailure = true
                    self.logger.error(
                        "DLSM Temporal GPU work failed: \(reason, privacy: .public)"
                    )
                }
                return
            }

            let gpuDuration =
                completedBuffer.gpuEndTime - completedBuffer.gpuStartTime
            guard gpuDuration.isFinite, gpuDuration > 0 else {
                return
            }

            if let timing = self.temporalGPUTiming.record(
                milliseconds: gpuDuration * 1_000
            ) {
                self.logger.info(
                    "DLSM Temporal \(source.rawValue, privacy: .public) GPU work: avg \(timing.averageMilliseconds, format: .fixed(precision: 2), privacy: .public) ms, p95 \(timing.p95Milliseconds, format: .fixed(precision: 2), privacy: .public) ms across \(timing.sampleCount, privacy: .public) frames"
                )
            }
        }
    }

    private func invalidatePipeline() {
        dimensions = nil
        spatialScaler = nil
        temporalScaler = nil
        temporalInputProvider = nil
        temporalInputProviderSource = nil
        frameInterpolatorObject = nil
        downsamplePipeline = nil
        downsampledColorTexture = nil
        currentUpscaledTexture = nil
        previousUpscaledTexture = nil
        resetMetalFXHistory = true
        hasUpscaledHistory = false
        didLogMissingCamera = false
        telemetryLock.withLock {
            didLogCommandBufferFailure = false
        }
        temporalGPUTiming.reset()
    }

    private static func declaredColorFormat(
        _ format: DLSMTextureFormat,
        matches texture: any MTLTexture
    ) -> Bool {
        switch format {
        case .bgra8Unorm:
            texture.pixelFormat == .bgra8Unorm
        case .bgra8UnormSRGB:
            texture.pixelFormat == .bgra8Unorm_srgb
        case .unknown:
            texture.pixelFormat == .bgra8Unorm ||
                texture.pixelFormat == .bgra8Unorm_srgb
        case .r32Float, .rg16Float:
            false
        }
    }

    private static func object<T>(at pointer: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    /// MoltenVK exports borrowed Objective-C objects that are guaranteed only
    /// for the synchronous frame callback. Retain each active queue once for
    /// the DLSM session so every frame does not race teardown while bridging
    /// the same opaque pointer back into Swift.
    private func commandQueue(
        at pointer: UnsafeMutableRawPointer
    ) -> (any MTLCommandQueue)? {
        let key = UInt(bitPattern: pointer)
        if let cachedCommandQueue = cachedCommandQueues[key] {
            return cachedCommandQueue
        }

        guard let commandQueue = Self.object(
            at: pointer,
            as: (any MTLCommandQueue).self
        ) else {
            return nil
        }

        if cachedCommandQueues.count >= 2 {
            cachedCommandQueues.removeAll(keepingCapacity: true)
        }
        cachedCommandQueues[key] = commandQueue
        return commandQueue
    }

    /// A swapchain normally exposes three textures. Keep a bounded strong set
    /// until `endSession()` closes presentation, then release it before the
    /// managed Vulkan renderer destroys its image views.
    private func texture(
        at pointer: UnsafeMutableRawPointer
    ) -> (any MTLTexture)? {
        let key = UInt(bitPattern: pointer)
        if let cachedTexture = cachedTextures[key] {
            return cachedTexture
        }

        guard let texture = Self.object(
            at: pointer,
            as: (any MTLTexture).self
        ) else {
            return nil
        }

        if cachedTextures.count >= 8 {
            cachedTextures.removeAll(keepingCapacity: true)
        }
        cachedTextures[key] = texture
        return texture
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void dlsmDownsample(
        texture2d<half, access::sample> source [[texture(0)]],
        texture2d<half, access::write> destination [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        const uint width = destination.get_width();
        const uint height = destination.get_height();
        if (gid.x >= width || gid.y >= height) {
            return;
        }

        constexpr sampler linearSampler(
            coord::normalized,
            address::clamp_to_edge,
            filter::linear
        );
        const float2 coordinate = (float2(gid) + 0.5) / float2(width, height);
        destination.write(source.sample(linearSampler, coordinate), gid);
    }
    """
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
