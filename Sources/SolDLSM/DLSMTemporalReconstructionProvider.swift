import Metal

struct DLSMReconstructedTemporalInputs {
    let depthTexture: any MTLTexture
    let motionTexture: any MTLTexture
    let reactiveMaskTexture: any MTLTexture
}

enum DLSMTemporalReconstructionProviderError: Error {
    case missingShaderFunction
    case textureAllocationFailed
}

/// Produces conservative Temporal inputs when a guest title does not expose
/// game-authored motion vectors through the renderer bridge.
///
/// The provider stays entirely on the engine's Metal command queue. It builds a
/// quarter-resolution luminance history, estimates bounded current-to-previous
/// motion, expands that motion to the DLSM input size, and marks ambiguous or
/// newly revealed pixels reactive so MetalFX prefers the current frame there.
///
/// This is deliberately isolated inside SolDLSM: a future Sol-trained model can
/// replace the estimator without changing the engine ABI or presentation path.
final class DLSMTemporalReconstructionProvider: DLSMTemporalInputProvider {
    private struct FlowParameters {
        var fullWidth: UInt32
        var fullHeight: UInt32
        var coarseWidth: UInt32
        var coarseHeight: UInt32
        var hasHistory: UInt32
        var searchRadius: UInt32
        var reserved0: UInt32 = 0
        var reserved1: UInt32 = 0
        var reactiveLow: Float = 0.025
        var reactiveHigh: Float = 0.14
        var motionLimit: Float = 32
        var motionBias: Float = 0.0008
    }

    let inputWidth: Int
    let inputHeight: Int

    private let coarseWidth: Int
    private let coarseHeight: Int
    private let luminancePipeline: any MTLComputePipelineState
    private let flowPipeline: any MTLComputePipelineState
    private let expandPipeline: any MTLComputePipelineState
    private let currentLuminance: any MTLTexture
    private let previousLuminance: any MTLTexture
    private let coarseMotion: any MTLTexture
    private let coarseReactiveMask: any MTLTexture
    private let depthTexture: any MTLTexture
    private let motionTexture: any MTLTexture
    private let reactiveMaskTexture: any MTLTexture
    private var hasHistory = false

    let identifier = "metal-block-matcher-v1"

    init(device: any MTLDevice, inputWidth: Int, inputHeight: Int) throws {
        guard inputWidth > 0, inputHeight > 0 else {
            throw DLSMTemporalReconstructionProviderError.textureAllocationFailed
        }

        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.coarseWidth = max(1, (inputWidth + 3) / 4)
        self.coarseHeight = max(1, (inputHeight + 3) / 4)

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let luminanceFunction = library.makeFunction(name: "dlsmTemporalLuminance"),
                  let flowFunction = library.makeFunction(name: "dlsmTemporalFlow"),
                  let expandFunction = library.makeFunction(name: "dlsmTemporalExpand") else {
                throw DLSMTemporalReconstructionProviderError.missingShaderFunction
            }
            luminancePipeline = try device.makeComputePipelineState(
                function: luminanceFunction
            )
            flowPipeline = try device.makeComputePipelineState(function: flowFunction)
            expandPipeline = try device.makeComputePipelineState(function: expandFunction)
        } catch {
            throw error
        }

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
            throw DLSMTemporalReconstructionProviderError.textureAllocationFailed
        }

        self.currentLuminance = currentLuminance
        self.previousLuminance = previousLuminance
        self.coarseMotion = coarseMotion
        self.coarseReactiveMask = coarseReactiveMask
        self.depthTexture = depthTexture
        self.motionTexture = motionTexture
        self.reactiveMaskTexture = reactiveMaskTexture
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

        guard let luminanceEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        luminanceEncoder.label = "DLSM Temporal Luminance"
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

        var parameters = FlowParameters(
            fullWidth: UInt32(inputWidth),
            fullHeight: UInt32(inputHeight),
            coarseWidth: UInt32(coarseWidth),
            coarseHeight: UInt32(coarseHeight),
            hasHistory: hasHistory ? 1 : 0,
            searchRadius: 4
        )

        guard let flowEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        flowEncoder.label = "DLSM Temporal Motion"
        flowEncoder.setComputePipelineState(flowPipeline)
        flowEncoder.setTexture(currentLuminance, index: 0)
        flowEncoder.setTexture(previousLuminance, index: 1)
        flowEncoder.setTexture(coarseMotion, index: 2)
        flowEncoder.setTexture(coarseReactiveMask, index: 3)
        flowEncoder.setBytes(
            &parameters,
            length: MemoryLayout<FlowParameters>.stride,
            index: 0
        )
        dispatch(
            encoder: flowEncoder,
            pipeline: flowPipeline,
            width: coarseWidth,
            height: coarseHeight
        )
        flowEncoder.endEncoding()

        guard let expandEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        expandEncoder.label = "DLSM Temporal Canonical Inputs"
        expandEncoder.setComputePipelineState(expandPipeline)
        expandEncoder.setTexture(coarseMotion, index: 0)
        expandEncoder.setTexture(coarseReactiveMask, index: 1)
        expandEncoder.setTexture(motionTexture, index: 2)
        expandEncoder.setTexture(depthTexture, index: 3)
        expandEncoder.setTexture(reactiveMaskTexture, index: 4)
        expandEncoder.setBytes(
            &parameters,
            length: MemoryLayout<FlowParameters>.stride,
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
        blitEncoder.label = "DLSM Temporal History"
        blitEncoder.copy(
            from: currentLuminance,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: coarseWidth, height: coarseHeight, depth: 1),
            to: previousLuminance,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin()
        )
        blitEncoder.endEncoding()
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
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
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

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DLSMFlowParameters {
        uint fullWidth;
        uint fullHeight;
        uint coarseWidth;
        uint coarseHeight;
        uint hasHistory;
        uint searchRadius;
        uint reserved0;
        uint reserved1;
        float reactiveLow;
        float reactiveHigh;
        float motionLimit;
        float motionBias;
    };

    inline int2 dlsmClampCoordinate(
        int2 coordinate,
        texture2d<half, access::read> image)
    {
        return clamp(
            coordinate,
            int2(0),
            int2(int(image.get_width()) - 1, int(image.get_height()) - 1)
        );
    }

    inline float dlsmReadLuminance(
        texture2d<half, access::read> image,
        int2 coordinate)
    {
        return float(image.read(uint2(dlsmClampCoordinate(coordinate, image))).r);
    }

    inline float dlsmFlowCost(
        texture2d<half, access::read> currentImage,
        texture2d<half, access::read> previousImage,
        int2 coordinate,
        int2 offset)
    {
        constexpr int2 taps[] = {
            int2(0, 0),
            int2(-1, 0),
            int2(1, 0),
            int2(0, -1),
            int2(0, 1),
            int2(-1, -1),
            int2(1, 1)
        };
        constexpr float weights[] = {
            0.28,
            0.12,
            0.12,
            0.12,
            0.12,
            0.12,
            0.12
        };

        float cost = 0.0;
        for (uint index = 0; index < 7; index++) {
            const int2 tap = taps[index];
            cost += weights[index] * abs(
                dlsmReadLuminance(currentImage, coordinate + tap) -
                dlsmReadLuminance(previousImage, coordinate + offset + tap)
            );
        }
        return cost;
    }

    kernel void dlsmTemporalLuminance(
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
        const float3 color = float3(source.sample(linearSampler, coordinate).rgb);
        const half luminance = half(
            dot(color, float3(0.2126, 0.7152, 0.0722))
        );
        destination.write(half4(luminance, 0.0, 0.0, 1.0), gid);
    }

    kernel void dlsmTemporalFlow(
        texture2d<half, access::read> currentImage [[texture(0)]],
        texture2d<half, access::read> previousImage [[texture(1)]],
        texture2d<half, access::write> outputMotion [[texture(2)]],
        texture2d<half, access::write> outputReactive [[texture(3)]],
        constant DLSMFlowParameters& parameters [[buffer(0)]],
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

        const int2 coordinate = int2(gid);
        const float zeroMotionCost = dlsmFlowCost(
            currentImage,
            previousImage,
            coordinate,
            int2(0)
        );
        float bestCost = INFINITY;
        float secondCost = INFINITY;
        int2 bestOffset = int2(0);

        for (int y = -4; y <= 4; y++) {
            for (int x = -4; x <= 4; x++) {
                if (abs(x) > int(parameters.searchRadius) ||
                    abs(y) > int(parameters.searchRadius)) {
                    continue;
                }

                const int2 offset = int2(x, y);
                const float cost =
                    dlsmFlowCost(
                        currentImage,
                        previousImage,
                        coordinate,
                        offset
                    ) +
                    length(float2(offset)) * parameters.motionBias;
                if (cost < bestCost) {
                    secondCost = bestCost;
                    bestCost = cost;
                    bestOffset = offset;
                } else if (cost < secondCost) {
                    secondCost = cost;
                }
            }
        }

        const float uniqueness = clamp(
            (secondCost - bestCost) / max(secondCost, 0.0001),
            0.0,
            1.0
        );
        const float improvement = clamp(
            (zeroMotionCost - bestCost) / max(zeroMotionCost, 0.0001),
            0.0,
            1.0
        );
        const bool hasMotion = any(bestOffset != int2(0));
        const bool touchesSearchBoundary =
            max(abs(bestOffset.x), abs(bestOffset.y)) >=
            int(parameters.searchRadius);
        const float matchConfidence =
            1.0 - smoothstep(
                parameters.reactiveLow,
                parameters.reactiveHigh,
                bestCost
            );
        const float motionConfidence = hasMotion
            ? matchConfidence *
                smoothstep(0.035, 0.18, improvement) *
                smoothstep(0.01, 0.08, uniqueness)
            : matchConfidence;
        const bool trustsMotion =
            !touchesSearchBoundary && motionConfidence >= 0.4;

        const float2 coarseToFull = float2(
            parameters.fullWidth / float(parameters.coarseWidth),
            parameters.fullHeight / float(parameters.coarseHeight)
        );
        float2 motion = trustsMotion
            ? float2(bestOffset) * coarseToFull
            : float2(0.0);
        motion = clamp(
            motion,
            float2(-parameters.motionLimit),
            float2(parameters.motionLimit)
        );

        const float center = dlsmReadLuminance(currentImage, coordinate);
        const float contrast = max(
            abs(center - dlsmReadLuminance(currentImage, coordinate + int2(1, 0))),
            abs(center - dlsmReadLuminance(currentImage, coordinate + int2(0, 1)))
        );
        const float ambiguity = 1.0 - uniqueness;
        const float errorReactive = smoothstep(
            parameters.reactiveLow,
            parameters.reactiveHigh,
            bestCost
        );
        const float ambiguityReactive =
            smoothstep(0.015, 0.08, contrast) * ambiguity * 0.8;
        const float confidenceReactive = trustsMotion
            ? 1.0 - motionConfidence
            : hasMotion || zeroMotionCost >= parameters.reactiveLow
                ? 1.0
                : errorReactive;
        const float reactive = clamp(
            max(
                max(errorReactive, ambiguityReactive),
                confidenceReactive
            ),
            0.0,
            1.0
        );

        outputMotion.write(half4(half2(motion), 0.0, 1.0), gid);
        outputReactive.write(half4(half(reactive), 0.0, 0.0, 1.0), gid);
    }

    kernel void dlsmTemporalExpand(
        texture2d<half, access::sample> coarseMotion [[texture(0)]],
        texture2d<half, access::sample> coarseReactive [[texture(1)]],
        texture2d<half, access::write> outputMotion [[texture(2)]],
        texture2d<float, access::write> outputDepth [[texture(3)]],
        texture2d<half, access::write> outputReactive [[texture(4)]],
        constant DLSMFlowParameters& parameters [[buffer(0)]],
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
        const float2 coarseTexel = 1.0 /
            float2(parameters.coarseWidth, parameters.coarseHeight);
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
