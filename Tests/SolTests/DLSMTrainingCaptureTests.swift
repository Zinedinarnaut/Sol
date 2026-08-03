import Metal
import XCTest
@testable import SolDLSM

final class DLSMTrainingCaptureTests: XCTestCase {
    func testV2CaptureWritesAdjacentSessionSafeLuminanceFrames() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal is unavailable on this test host")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sol-capture-test-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let capture = try DLSMTrainingCapture(
            directoryURL: directory,
            interval: 1,
            maximumFramesPerSession: 2
        )
        capture.beginSession(captureGroup: "test-title")
        let texture = try makeTexture(
            device: device,
            width: 64,
            height: 40
        )

        for frameID: UInt64 in 1...2 {
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            capture.encode(
                frameID: frameID,
                presentationTimestampNanoseconds:
                    frameID * 16_666_667,
                texture: texture,
                commandBuffer: commandBuffer,
                discontinuity: false
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed)
        }
        capture.endSession()
        capture.flushWrites()

        let metadataURLs = try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(metadataURLs.count, 2)
        let metadata = try metadataURLs.map {
            try JSONDecoder().decode(
                DLSMTrainingCapture.Metadata.self,
                from: Data(contentsOf: $0)
            )
        }

        XCTAssertEqual(metadata.map(\.schemaVersion), [2, 2])
        XCTAssertEqual(Set(metadata.map(\.sessionID)).count, 1)
        XCTAssertEqual(metadata.map(\.captureGroup), [
            "test-title",
            "test-title",
        ])
        XCTAssertEqual(metadata.map(\.sequenceIndex), [1, 2])
        XCTAssertEqual(metadata.map(\.frameID), [1, 2])
        XCTAssertEqual(metadata.map(\.pixelLayout), ["L8", "L8"])
        XCTAssertEqual(metadata.map(\.width), [16, 16])
        XCTAssertEqual(metadata.map(\.height), [10, 10])
        XCTAssertEqual(metadata.map(\.sourceWidth), [64, 64])
        XCTAssertEqual(metadata.map(\.sourceHeight), [40, 40])

        for metadataURL in metadataURLs {
            let payloadURL = metadataURL
                .deletingPathExtension()
                .appendingPathExtension("luma")
            XCTAssertEqual(
                try Data(contentsOf: payloadURL).count,
                16 * 10
            )
        }
    }

    private func makeTexture(
        device: any MTLDevice,
        width: Int,
        height: Int
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixels = [UInt8](
            repeating: 128,
            count: width * height * 4
        )
        pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        return texture
    }
}
