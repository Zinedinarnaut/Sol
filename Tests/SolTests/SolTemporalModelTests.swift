import Metal
import XCTest
@testable import SolDLSM

final class SolTemporalModelTests: XCTestCase {
    func testBundledCandidateLoadsAndUnlocksPreferredModel() throws {
        let model = try XCTUnwrap(
            SolTemporalModel.preferred(environment: [:])
        )

        XCTAssertEqual(
            model.identifier,
            "sol-flow-reactive-v1-0d8f9c7a5d5e"
        )
        XCTAssertEqual(model.motionLimit, 8)
        XCTAssertEqual(
            model.conv1Weights.count,
            SolTemporalModel.conv1WeightCount
        )
        XCTAssertEqual(
            model.conv2Weights.count,
            SolTemporalModel.conv2WeightCount
        )
    }

    func testValidArtifactDecodesExactMetalTensorShapes() throws {
        let model = try SolTemporalModel.decode(data: artifactData())

        XCTAssertEqual(model.identifier, "sol-flow-reactive-v0-test")
        XCTAssertEqual(model.motionLimit, 8)
        XCTAssertEqual(
            model.conv1Weights.count,
            SolTemporalModel.conv1WeightCount
        )
        XCTAssertEqual(
            model.conv2Weights.count,
            SolTemporalModel.conv2WeightCount
        )
    }

    func testArtifactRejectsWrongSchemaAndArchitecture() {
        XCTAssertThrowsError(
            try SolTemporalModel.decode(
                data: artifactData(schemaVersion: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? SolTemporalModelError,
                .unsupportedSchema(2)
            )
        }

        XCTAssertThrowsError(
            try SolTemporalModel.decode(
                data: artifactData(architecture: "unknown")
            )
        ) { error in
            XCTAssertEqual(
                error as? SolTemporalModelError,
                .unsupportedArchitecture("unknown")
            )
        }
    }

    func testArtifactRejectsUnsafeIdentifierAndTensorShape() {
        XCTAssertThrowsError(
            try SolTemporalModel.decode(
                data: artifactData(identifier: "../../model")
            )
        ) { error in
            XCTAssertEqual(
                error as? SolTemporalModelError,
                .invalidIdentifier
            )
        }

        XCTAssertThrowsError(
            try SolTemporalModel.decode(
                data: artifactData(conv2WeightCount: 4)
            )
        ) { error in
            XCTAssertEqual(
                error as? SolTemporalModelError,
                .invalidWeightCount(
                    name: "conv2",
                    expected: SolTemporalModel.conv2WeightCount,
                    actual: 4
                )
            )
        }
    }

    func testMetalProviderProducesCanonicalTexturesAndRejectsSceneCutHistory() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal is unavailable on this test host")
        }

        let width = 64
        let height = 64
        let provider = try DLSMSolTemporalModelProvider(
            device: device,
            inputWidth: width,
            inputHeight: height,
            model: model(),
            profilesGPU: true
        )
        let dark = try makeSolidTexture(
            device: device,
            width: width,
            height: height,
            value: 8
        )
        let firstCommandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertNotNil(
            provider.encode(
                sourceTexture: dark,
                commandBuffer: firstCommandBuffer,
                resetHistory: true
            )
        )
        let firstTimingCompleted = expectation(
            description: "first model timing callback"
        )
        firstCommandBuffer.addCompletedHandler { _ in
            firstTimingCompleted.fulfill()
        }
        firstCommandBuffer.commit()
        firstCommandBuffer.waitUntilCompleted()
        wait(for: [firstTimingCompleted], timeout: 1)
        XCTAssertEqual(firstCommandBuffer.status, .completed)

        let bright = try makeSolidTexture(
            device: device,
            width: width,
            height: height,
            value: 240
        )
        let secondCommandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try XCTUnwrap(
            provider.encode(
                sourceTexture: bright,
                commandBuffer: secondCommandBuffer,
                resetHistory: false
            )
        )
        XCTAssertEqual(output.depthTexture.pixelFormat, .r32Float)
        XCTAssertEqual(output.motionTexture.pixelFormat, .rg16Float)
        XCTAssertEqual(output.reactiveMaskTexture.pixelFormat, .r8Unorm)

        let bytesPerRow = 256
        let readback = try XCTUnwrap(
            device.makeBuffer(
                length: bytesPerRow * height,
                options: .storageModeShared
            )
        )
        let blit = try XCTUnwrap(secondCommandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: output.reactiveMaskTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        let secondTimingCompleted = expectation(
            description: "second model timing callback"
        )
        secondCommandBuffer.addCompletedHandler { _ in
            secondTimingCompleted.fulfill()
        }
        secondCommandBuffer.commit()
        secondCommandBuffer.waitUntilCompleted()
        wait(for: [secondTimingCompleted], timeout: 1)
        XCTAssertEqual(secondCommandBuffer.status, .completed)
        if device.supportsCounterSampling(.atStageBoundary) {
            let timing = try XCTUnwrap(provider.gpuTimingSnapshot)
            // Metal can omit the first stage-boundary timestamp while its
            // counter sample buffer warms up.
            XCTAssertGreaterThanOrEqual(timing.sampleCount, 1)
            XCTAssertLessThanOrEqual(timing.sampleCount, 2)
            XCTAssertGreaterThan(timing.averageMilliseconds, 0)
            XCTAssertLessThan(timing.averageMilliseconds, 20)
        }

        let reactiveValue = readback.contents()
            .advanced(by: 32 * bytesPerRow + 32)
            .load(as: UInt8.self)
        XCTAssertGreaterThanOrEqual(reactiveValue, 250)
    }

    private func model() -> SolTemporalModel {
        SolTemporalModel(
            identifier: "sol-flow-reactive-v0-test",
            motionLimit: 8,
            conv1Weights: Array(
                repeating: 0,
                count: SolTemporalModel.conv1WeightCount
            ),
            conv1Bias: Array(
                repeating: 0,
                count: SolTemporalModel.conv1BiasCount
            ),
            conv2Weights: Array(
                repeating: 0,
                count: SolTemporalModel.conv2WeightCount
            ),
            conv2Bias: Array(
                repeating: 0,
                count: SolTemporalModel.conv2BiasCount
            )
        )
    }

    private func artifactData(
        schemaVersion: Int = SolTemporalModel.schemaVersion,
        identifier: String = "sol-flow-reactive-v0-test",
        architecture: String = SolTemporalModel.architecture,
        conv2WeightCount: Int = SolTemporalModel.conv2WeightCount
    ) -> Data {
        try! JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": schemaVersion,
                "identifier": identifier,
                "architecture": architecture,
                "coarseScale": SolTemporalModel.coarseScale,
                "motionLimit": 8,
                "weights": [
                    "conv1": Array(
                        repeating: 0,
                        count: SolTemporalModel.conv1WeightCount
                    ),
                    "conv1Bias": Array(
                        repeating: 0,
                        count: SolTemporalModel.conv1BiasCount
                    ),
                    "conv2": Array(
                        repeating: 0,
                        count: conv2WeightCount
                    ),
                    "conv2Bias": Array(
                        repeating: 0,
                        count: SolTemporalModel.conv2BiasCount
                    ),
                ],
            ],
            options: [.sortedKeys]
        )
    }

    private func makeSolidTexture(
        device: any MTLDevice,
        width: Int,
        height: Int,
        value: UInt8
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(
            device.makeTexture(descriptor: descriptor)
        )
        let pixel = [value, value, value, UInt8.max]
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            bytes.append(contentsOf: pixel)
        }
        bytes.withUnsafeBytes { rawBytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: rawBytes.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        return texture
    }
}
