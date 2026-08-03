import Metal
import OSLog

enum DLSMSolTemporalModelProviderError: Error {
    case missingShaderFunction
    case bufferAllocationFailed
    case textureAllocationFailed
}

/// Runs a compact Sol-trained motion-and-reactive network entirely on Metal.
///
/// The provider consumes the same low-resolution texture as the Spatial path
/// and emits the canonical inputs expected by MetalFX Temporal. Model weights
/// are local, versioned, and validated by `SolTemporalModel` before any Metal
/// resources are allocated.
final class DLSMSolTemporalModelProvider: DLSMTemporalInputProvider,
    @unchecked Sendable {
    private struct GPUTimingResources: @unchecked Sendable {
        let sampleBuffer: any MTLCounterSampleBuffer
        let resolveBuffer: any MTLBuffer
    }

    private struct Parameters {
        var fullWidth: UInt32
        var fullHeight: UInt32
        var coarseWidth: UInt32
        var coarseHeight: UInt32
        var hasHistory: UInt32
        var coarseScale: UInt32
        var reserved0: UInt32 = 0
        var reserved1: UInt32 = 0
        var motionLimit: Float
        var reactiveFloor: Float = 0.025
        var residualLow: Float = 0.035
        var residualHigh: Float = 0.14
    }

    let identifier: String

    private let inputWidth: Int
    private let inputHeight: Int
    private let coarseWidth: Int
    private let coarseHeight: Int
    private let motionLimit: Float
    private let luminancePipeline: any MTLComputePipelineState
    private let conv1Pipeline: any MTLComputePipelineState
    private let conv2Pipeline: any MTLComputePipelineState
    private let expandPipeline: any MTLComputePipelineState
    private let conv1Weights: any MTLBuffer
    private let conv1Bias: any MTLBuffer
    private let conv2Weights: any MTLBuffer
    private let conv2Bias: any MTLBuffer
    private let currentLuminance: any MTLTexture
    private let previousLuminance: any MTLTexture
    private let feature0: any MTLTexture
    private let feature1: any MTLTexture
    private let coarseMotion: any MTLTexture
    private let coarseReactiveMask: any MTLTexture
    private let depthTexture: any MTLTexture
    private let motionTexture: any MTLTexture
    private let reactiveMaskTexture: any MTLTexture
    private let gpuTimingResources: GPUTimingResources?
    private let gpuTiming = DLSMGPUTimingAccumulator()
    private let logger = Logger(
        subsystem: "com.solemu.app",
        category: "DLSMModel"
    )
    private var hasHistory = false

    var gpuTimingSnapshot: DLSMGPUTimingSnapshot? {
        gpuTiming.snapshot
    }

    init(
        device: any MTLDevice,
        inputWidth: Int,
        inputHeight: Int,
        model: SolTemporalModel,
        profilesGPU: Bool =
            ProcessInfo.processInfo.environment[
                "SOL_DLSM_PROFILE_MODEL"
            ] == "1"
    ) throws {
        guard inputWidth > 0, inputHeight > 0 else {
            throw DLSMSolTemporalModelProviderError.textureAllocationFailed
        }

        self.identifier = model.identifier
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.coarseWidth = max(
            1,
            (inputWidth + SolTemporalModel.coarseScale - 1) /
                SolTemporalModel.coarseScale
        )
        self.coarseHeight = max(
            1,
            (inputHeight + SolTemporalModel.coarseScale - 1) /
                SolTemporalModel.coarseScale
        )
        self.motionLimit = model.motionLimit

        let library = try device.makeLibrary(
            source: Self.shaderSource,
            options: nil
        )
        guard let luminanceFunction = library.makeFunction(
                  name: "dlsmSolLuminance"
              ),
              let conv1Function = library.makeFunction(name: "dlsmSolConv1"),
              let conv2Function = library.makeFunction(name: "dlsmSolConv2"),
              let expandFunction = library.makeFunction(name: "dlsmSolExpand") else {
            throw DLSMSolTemporalModelProviderError.missingShaderFunction
        }

        luminancePipeline = try device.makeComputePipelineState(
            function: luminanceFunction
        )
        conv1Pipeline = try device.makeComputePipelineState(
            function: conv1Function
        )
        conv2Pipeline = try device.makeComputePipelineState(
            function: conv2Function
        )
        expandPipeline = try device.makeComputePipelineState(
            function: expandFunction
        )

        guard let conv1Weights = Self.makeBuffer(
                  device: device,
                  values: model.conv1Weights
              ),
              let conv1Bias = Self.makeBuffer(
                  device: device,
                  values: model.conv1Bias
              ),
              let conv2Weights = Self.makeBuffer(
                  device: device,
                  values: model.conv2Weights
              ),
              let conv2Bias = Self.makeBuffer(
                  device: device,
                  values: model.conv2Bias
              ) else {
            throw DLSMSolTemporalModelProviderError.bufferAllocationFailed
        }
        self.conv1Weights = conv1Weights
        self.conv1Bias = conv1Bias
        self.conv2Weights = conv2Weights
        self.conv2Bias = conv2Bias

        guard let currentLuminance = Self.makeTexture(
                  device: device,
                  pixelFormat: .r16Float,
                  width: coarseWidth,
                  height: coarseHeight,
                  usage: [.shaderRead, .shaderWrite]
              ),
              let previousLuminance = Self.makeTexture(
                  device: device,
                  pixelFormat: .r16Float,
                  width: coarseWidth,
                  height: coarseHeight,
                  usage: [.shaderRead, .shaderWrite]
              ),
              let feature0 = Self.makeTexture(
                  device: device,
                  pixelFormat: .rgba16Float,
                  width: coarseWidth,
                  height: coarseHeight,
                  usage: [.shaderRead, .shaderWrite]
              ),
              let feature1 = Self.makeTexture(
                  device: device,
                  pixelFormat: .rgba16Float,
                  width: coarseWidth,
                  height: coarseHeight,
                  usage: [.shaderRead, .shaderWrite]
              ),
              let coarseMotion = Self.makeTexture(
                  device: device,
                  pixelFormat: .rg16Float,
                  width: coarseWidth,
                  height: coarseHeight,
                  usage: [.shaderRead, .shaderWrite]
              ),
              let coarseReactiveMask = Self.makeTexture(
                  device: device,
                  pixelFormat: .r16Float,
                  width: coarseWidth,
                  height: coarseHeight,
                  usage: [.shaderRead, .shaderWrite]
              ),
              let depthTexture = Self.makeTexture(
                  device: device,
                  pixelFormat: .r32Float,
                  width: inputWidth,
                  height: inputHeight,
                  usage: [.shaderRead, .shaderWrite]
              ),
              let motionTexture = Self.makeTexture(
                  device: device,
                  pixelFormat: .rg16Float,
                  width: inputWidth,
                  height: inputHeight,
                  usage: [.shaderRead, .shaderWrite]
              ),
              let reactiveMaskTexture = Self.makeTexture(
                  device: device,
                  pixelFormat: .r8Unorm,
                  width: inputWidth,
                  height: inputHeight,
                  usage: [.shaderRead, .shaderWrite]
              ) else {
            throw DLSMSolTemporalModelProviderError.textureAllocationFailed
        }

        self.currentLuminance = currentLuminance
        self.previousLuminance = previousLuminance
        self.feature0 = feature0
        self.feature1 = feature1
        self.coarseMotion = coarseMotion
        self.coarseReactiveMask = coarseReactiveMask
        self.depthTexture = depthTexture
        self.motionTexture = motionTexture
        self.reactiveMaskTexture = reactiveMaskTexture
        self.gpuTimingResources = profilesGPU
            ? Self.makeGPUTimingResources(device: device)
            : nil
    }

    func resetHistory() {
        hasHistory = false
    }

    func encode(
        sourceTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        resetHistory: Bool
    ) -> DLSMReconstructedTemporalInputs? {
        guard sourceTexture.width == inputWidth,
              sourceTexture.height == inputHeight,
              sourceTexture.usage.contains(.shaderRead) else {
            return nil
        }

        if resetHistory {
            hasHistory = false
        }

        var parameters = Parameters(
            fullWidth: UInt32(inputWidth),
            fullHeight: UInt32(inputHeight),
            coarseWidth: UInt32(coarseWidth),
            coarseHeight: UInt32(coarseHeight),
            hasHistory: hasHistory ? 1 : 0,
            coarseScale: UInt32(SolTemporalModel.coarseScale),
            motionLimit: motionLimit
        )

        guard let luminanceEncoder = makeComputeEncoder(
            commandBuffer: commandBuffer,
            sampleStart: true
        ) else {
            return nil
        }
        luminanceEncoder.label = "DLSM Sol Model Luminance"
        luminanceEncoder.setComputePipelineState(luminancePipeline)
        luminanceEncoder.setTexture(sourceTexture, index: 0)
        luminanceEncoder.setTexture(currentLuminance, index: 1)
        dispatch(
            encoder: luminanceEncoder,
            pipeline: luminancePipeline,
            width: coarseWidth,
            height: coarseHeight
        )
        luminanceEncoder.endEncoding()

        guard let conv1Encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        conv1Encoder.label = "DLSM Sol Model Features"
        conv1Encoder.setComputePipelineState(conv1Pipeline)
        conv1Encoder.setTexture(currentLuminance, index: 0)
        conv1Encoder.setTexture(previousLuminance, index: 1)
        conv1Encoder.setTexture(feature0, index: 2)
        conv1Encoder.setTexture(feature1, index: 3)
        conv1Encoder.setBuffer(conv1Weights, offset: 0, index: 0)
        conv1Encoder.setBuffer(conv1Bias, offset: 0, index: 1)
        conv1Encoder.setBytes(
            &parameters,
            length: MemoryLayout<Parameters>.stride,
            index: 2
        )
        dispatch(
            encoder: conv1Encoder,
            pipeline: conv1Pipeline,
            width: coarseWidth,
            height: coarseHeight
        )
        conv1Encoder.endEncoding()

        guard let conv2Encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        conv2Encoder.label = "DLSM Sol Model Motion"
        conv2Encoder.setComputePipelineState(conv2Pipeline)
        conv2Encoder.setTexture(currentLuminance, index: 0)
        conv2Encoder.setTexture(previousLuminance, index: 1)
        conv2Encoder.setTexture(feature0, index: 2)
        conv2Encoder.setTexture(feature1, index: 3)
        conv2Encoder.setTexture(coarseMotion, index: 4)
        conv2Encoder.setTexture(coarseReactiveMask, index: 5)
        conv2Encoder.setBuffer(conv2Weights, offset: 0, index: 0)
        conv2Encoder.setBuffer(conv2Bias, offset: 0, index: 1)
        conv2Encoder.setBytes(
            &parameters,
            length: MemoryLayout<Parameters>.stride,
            index: 2
        )
        dispatch(
            encoder: conv2Encoder,
            pipeline: conv2Pipeline,
            width: coarseWidth,
            height: coarseHeight
        )
        conv2Encoder.endEncoding()

        guard let expandEncoder = makeComputeEncoder(
            commandBuffer: commandBuffer,
            sampleEnd: true
        ) else {
            return nil
        }
        expandEncoder.label = "DLSM Sol Model Canonical Inputs"
        expandEncoder.setComputePipelineState(expandPipeline)
        expandEncoder.setTexture(coarseMotion, index: 0)
        expandEncoder.setTexture(coarseReactiveMask, index: 1)
        expandEncoder.setTexture(motionTexture, index: 2)
        expandEncoder.setTexture(depthTexture, index: 3)
        expandEncoder.setTexture(reactiveMaskTexture, index: 4)
        expandEncoder.setBytes(
            &parameters,
            length: MemoryLayout<Parameters>.stride,
            index: 0
        )
        dispatch(
            encoder: expandEncoder,
            pipeline: expandPipeline,
            width: inputWidth,
            height: inputHeight
        )
        expandEncoder.endEncoding()

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blitEncoder.label = "DLSM Sol Model History"
        blitEncoder.copy(
            from: currentLuminance,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(
                width: coarseWidth,
                height: coarseHeight,
                depth: 1
            ),
            to: previousLuminance,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin()
        )
        if let gpuTimingResources {
            blitEncoder.resolveCounters(
                gpuTimingResources.sampleBuffer,
                range: 0..<2,
                destinationBuffer: gpuTimingResources.resolveBuffer,
                destinationOffset: 0
            )
        }
        blitEncoder.endEncoding()
        installGPUTimingCompletion(on: commandBuffer)
        hasHistory = true

        return DLSMReconstructedTemporalInputs(
            depthTexture: depthTexture,
            motionTexture: motionTexture,
            reactiveMaskTexture: reactiveMaskTexture
        )
    }

    private func dispatch(
        encoder: any MTLComputeCommandEncoder,
        pipeline: any MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(
            1,
            pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
    }

    private func makeComputeEncoder(
        commandBuffer: any MTLCommandBuffer,
        sampleStart: Bool = false,
        sampleEnd: Bool = false
    ) -> (any MTLComputeCommandEncoder)? {
        guard let gpuTimingResources, sampleStart || sampleEnd else {
            return commandBuffer.makeComputeCommandEncoder()
        }

        let descriptor = MTLComputePassDescriptor()
        guard let attachment = descriptor.sampleBufferAttachments[0] else {
            return commandBuffer.makeComputeCommandEncoder()
        }
        attachment.sampleBuffer = gpuTimingResources.sampleBuffer
        attachment.startOfEncoderSampleIndex = sampleStart
            ? 0
            : MTLCounterDontSample
        attachment.endOfEncoderSampleIndex = sampleEnd
            ? 1
            : MTLCounterDontSample
        return commandBuffer.makeComputeCommandEncoder(
            descriptor: descriptor
        )
    }

    private func installGPUTimingCompletion(
        on commandBuffer: any MTLCommandBuffer
    ) {
        guard let gpuTimingResources else {
            return
        }
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            guard let self, completedBuffer.status == .completed else {
                return
            }
            let timestamps = gpuTimingResources.resolveBuffer.contents()
                .assumingMemoryBound(to: MTLCounterResultTimestamp.self)
            let start = timestamps[0].timestamp
            let end = timestamps[1].timestamp
            guard start != MTLCounterErrorValue,
                  end != MTLCounterErrorValue,
                  end > start else {
                return
            }

            // Apple GPU timestamp counters use nanosecond ticks.
            let milliseconds = Double(end - start) / 1_000_000
            if let timing = self.gpuTiming.record(
                milliseconds: milliseconds
            ) {
                self.logger.info(
                    "Sol Temporal model \(self.identifier, privacy: .public) inference: avg \(timing.averageMilliseconds, format: .fixed(precision: 3), privacy: .public) ms, p95 \(timing.p95Milliseconds, format: .fixed(precision: 3), privacy: .public) ms across \(timing.sampleCount, privacy: .public) frames"
                )
            }
        }
    }

    private static func makeBuffer(
        device: any MTLDevice,
        values: [Float]
    ) -> (any MTLBuffer)? {
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return nil
            }
            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
    }

    private static func makeTexture(
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

    private static func makeGPUTimingResources(
        device: any MTLDevice
    ) -> GPUTimingResources? {
        guard device.supportsCounterSampling(.atStageBoundary),
              let counterSets = device.counterSets,
              let timestampSet = counterSets.first(where: {
                  $0.name == MTLCommonCounterSet.timestamp.rawValue
              }) else {
            return nil
        }

        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = timestampSet
        descriptor.label = "DLSM Sol Model Inference Timing"
        descriptor.storageMode = .shared
        descriptor.sampleCount = 2
        guard let sampleBuffer = try? device.makeCounterSampleBuffer(
                  descriptor: descriptor
              ),
              let resolveBuffer = device.makeBuffer(
                  length: 256,
                  options: .storageModeShared
              ) else {
            return nil
        }
        return GPUTimingResources(
            sampleBuffer: sampleBuffer,
            resolveBuffer: resolveBuffer
        )
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DLSMSolParameters {
        uint fullWidth;
        uint fullHeight;
        uint coarseWidth;
        uint coarseHeight;
        uint hasHistory;
        uint coarseScale;
        uint reserved0;
        uint reserved1;
        float motionLimit;
        float reactiveFloor;
        float residualLow;
        float residualHigh;
    };

    inline bool dlsmSolInside(int2 coordinate, uint width, uint height)
    {
        return coordinate.x >= 0 &&
            coordinate.y >= 0 &&
            coordinate.x < int(width) &&
            coordinate.y < int(height);
    }

    inline float dlsmSolReadLuminance(
        texture2d<half, access::read> image,
        int2 coordinate)
    {
        if (!dlsmSolInside(
                coordinate,
                image.get_width(),
                image.get_height())) {
            return 0.0;
        }
        return float(image.read(uint2(coordinate)).r);
    }

    inline float dlsmSolReadFeature(
        texture2d<half, access::read> feature0,
        texture2d<half, access::read> feature1,
        int2 coordinate,
        uint channel)
    {
        if (!dlsmSolInside(
                coordinate,
                feature0.get_width(),
                feature0.get_height())) {
            return 0.0;
        }
        const uint2 position = uint2(coordinate);
        return channel < 4
            ? float(feature0.read(position)[channel])
            : float(feature1.read(position)[channel - 4]);
    }

    kernel void dlsmSolLuminance(
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
        const float2 coordinate =
            (float2(gid) + 0.5) / float2(width, height);
        const float3 color = float3(
            source.sample(linearSampler, coordinate).rgb
        );
        const half luminance = half(
            dot(color, float3(0.2126, 0.7152, 0.0722))
        );
        destination.write(half4(luminance, 0.0, 0.0, 1.0), gid);
    }

    kernel void dlsmSolConv1(
        texture2d<half, access::read> currentImage [[texture(0)]],
        texture2d<half, access::read> previousImage [[texture(1)]],
        texture2d<half, access::write> output0 [[texture(2)]],
        texture2d<half, access::write> output1 [[texture(3)]],
        constant float* weights [[buffer(0)]],
        constant float* bias [[buffer(1)]],
        constant DLSMSolParameters& parameters [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= parameters.coarseWidth ||
            gid.y >= parameters.coarseHeight) {
            return;
        }

        if (parameters.hasHistory == 0) {
            output0.write(half4(0.0), gid);
            output1.write(half4(0.0), gid);
            return;
        }

        float features[8];
        const int2 center = int2(gid);
        for (uint outputChannel = 0; outputChannel < 8; outputChannel++) {
            float value = bias[outputChannel];
            for (int kernelY = 0; kernelY < 3; kernelY++) {
                for (int kernelX = 0; kernelX < 3; kernelX++) {
                    const int2 coordinate =
                        center + int2(kernelX - 1, kernelY - 1);
                    const float current = dlsmSolReadLuminance(
                        currentImage,
                        coordinate
                    );
                    const float previous = dlsmSolReadLuminance(
                        previousImage,
                        coordinate
                    );
                    const float input[4] = {
                        current,
                        previous,
                        current - previous,
                        abs(current - previous)
                    };
                    for (uint inputChannel = 0;
                         inputChannel < 4;
                         inputChannel++) {
                        const uint weightIndex =
                            (((outputChannel * 3 + uint(kernelY)) * 3 +
                                uint(kernelX)) * 4) +
                            inputChannel;
                        value += weights[weightIndex] * input[inputChannel];
                    }
                }
            }
            features[outputChannel] = max(value, 0.0);
        }

        output0.write(
            half4(
                half(features[0]),
                half(features[1]),
                half(features[2]),
                half(features[3])
            ),
            gid
        );
        output1.write(
            half4(
                half(features[4]),
                half(features[5]),
                half(features[6]),
                half(features[7])
            ),
            gid
        );
    }

    kernel void dlsmSolConv2(
        texture2d<half, access::read> currentImage [[texture(0)]],
        texture2d<half, access::read> previousImage [[texture(1)]],
        texture2d<half, access::read> feature0 [[texture(2)]],
        texture2d<half, access::read> feature1 [[texture(3)]],
        texture2d<half, access::write> outputMotion [[texture(4)]],
        texture2d<half, access::write> outputReactive [[texture(5)]],
        constant float* weights [[buffer(0)]],
        constant float* bias [[buffer(1)]],
        constant DLSMSolParameters& parameters [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= parameters.coarseWidth ||
            gid.y >= parameters.coarseHeight) {
            return;
        }

        if (parameters.hasHistory == 0) {
            outputMotion.write(half4(0.0, 0.0, 0.0, 1.0), gid);
            outputReactive.write(half4(1.0, 0.0, 0.0, 1.0), gid);
            return;
        }

        float output[3];
        const int2 center = int2(gid);
        for (uint outputChannel = 0; outputChannel < 3; outputChannel++) {
            float value = bias[outputChannel];
            for (int kernelY = 0; kernelY < 3; kernelY++) {
                for (int kernelX = 0; kernelX < 3; kernelX++) {
                    const int2 coordinate =
                        center + int2(kernelX - 1, kernelY - 1);
                    for (uint inputChannel = 0;
                         inputChannel < 8;
                         inputChannel++) {
                        const uint weightIndex =
                            (((outputChannel * 3 + uint(kernelY)) * 3 +
                                uint(kernelX)) * 8) +
                            inputChannel;
                        value += weights[weightIndex] * dlsmSolReadFeature(
                            feature0,
                            feature1,
                            coordinate,
                            inputChannel
                        );
                    }
                }
            }
            output[outputChannel] = value;
        }

        float2 motion = tanh(float2(output[0], output[1])) *
            parameters.motionLimit;
        motion = clamp(
            motion,
            float2(-parameters.motionLimit),
            float2(parameters.motionLimit)
        );

        float reactive = 1.0 / (1.0 + exp(-output[2]));
        const float2 coarseMotion =
            motion / max(float(parameters.coarseScale), 1.0);
        const int2 previousCoordinate = int2(round(float2(center) + coarseMotion));
        const float current = dlsmSolReadLuminance(currentImage, center);
        const float previous = dlsmSolReadLuminance(
            previousImage,
            previousCoordinate
        );
        const float residual = abs(current - previous);
        reactive = max(
            reactive,
            smoothstep(
                parameters.residualLow,
                parameters.residualHigh,
                residual
            )
        );
        reactive = clamp(
            max(reactive, parameters.reactiveFloor),
            0.0,
            1.0
        );

        outputMotion.write(half4(half2(motion), 0.0, 1.0), gid);
        outputReactive.write(
            half4(half(reactive), 0.0, 0.0, 1.0),
            gid
        );
    }

    kernel void dlsmSolExpand(
        texture2d<half, access::sample> coarseMotion [[texture(0)]],
        texture2d<half, access::sample> coarseReactive [[texture(1)]],
        texture2d<half, access::write> outputMotion [[texture(2)]],
        texture2d<float, access::write> outputDepth [[texture(3)]],
        texture2d<half, access::write> outputReactive [[texture(4)]],
        constant DLSMSolParameters& parameters [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= parameters.fullWidth || gid.y >= parameters.fullHeight) {
            return;
        }

        constexpr sampler linearSampler(
            coord::normalized,
            address::clamp_to_edge,
            filter::linear
        );
        const float2 coordinate =
            (float2(gid) + 0.5) /
            float2(parameters.fullWidth, parameters.fullHeight);
        const float2 coarseTexel =
            1.0 / float2(parameters.coarseWidth, parameters.coarseHeight);
        const float2 motion = float2(
            coarseMotion.sample(linearSampler, coordinate).rg
        );
        const float2 motionX = float2(
            coarseMotion.sample(
                linearSampler,
                coordinate + float2(coarseTexel.x, 0.0)
            ).rg
        );
        const float2 motionY = float2(
            coarseMotion.sample(
                linearSampler,
                coordinate + float2(0.0, coarseTexel.y)
            ).rg
        );
        const float divergence = max(
            length(motion - motionX),
            length(motion - motionY)
        ) / max(parameters.motionLimit, 1.0);
        float reactive = float(
            coarseReactive.sample(linearSampler, coordinate).r
        );
        reactive = max(reactive, smoothstep(0.08, 0.35, divergence));
        if (parameters.hasHistory == 0) {
            reactive = 1.0;
        }

        outputMotion.write(half4(half2(motion), 0.0, 1.0), gid);
        outputDepth.write(float4(1.0, 0.0, 0.0, 1.0), gid);
        outputReactive.write(
            half4(half(clamp(reactive, 0.0, 1.0)), 0.0, 0.0, 1.0),
            gid
        );
    }
    """
}
