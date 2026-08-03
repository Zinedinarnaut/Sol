import Metal
import MetalFX
import XCTest
@testable import SolDLSM

final class DLSMTemporalReconstructionProviderTests: XCTestCase {
    func testProviderProducesCanonicalMotionAndTracksAHorizontalShift() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal is unavailable on this test host")
        }

        let width = 64
        let height = 64
        let provider = try DLSMTemporalReconstructionProvider(
            device: device,
            inputWidth: width,
            inputHeight: height
        )

        let firstFrame = try makeTexture(
            device: device,
            width: width,
            height: height,
            horizontalShift: 0
        )
        let firstCommandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        let firstOutput = try XCTUnwrap(
            provider.encode(
                sourceTexture: firstFrame,
                commandBuffer: firstCommandBuffer,
                resetHistory: true
            )
        )
        firstCommandBuffer.commit()
        firstCommandBuffer.waitUntilCompleted()
        XCTAssertEqual(firstCommandBuffer.status, .completed)
        XCTAssertEqual(firstOutput.depthTexture.pixelFormat, .r32Float)
        XCTAssertEqual(firstOutput.motionTexture.pixelFormat, .rg16Float)
        XCTAssertEqual(firstOutput.reactiveMaskTexture.pixelFormat, .r8Unorm)
        XCTAssertEqual(firstOutput.motionTexture.width, width)
        XCTAssertEqual(firstOutput.motionTexture.height, height)

        let secondFrame = try makeTexture(
            device: device,
            width: width,
            height: height,
            horizontalShift: 4
        )
        let secondCommandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        let secondOutput = try XCTUnwrap(
            provider.encode(
                sourceTexture: secondFrame,
                commandBuffer: secondCommandBuffer,
                resetHistory: false
            )
        )

        let temporalDescriptor = MTLFXTemporalScalerDescriptor()
        temporalDescriptor.colorTextureFormat = .bgra8Unorm
        temporalDescriptor.depthTextureFormat = .r32Float
        temporalDescriptor.motionTextureFormat = .rg16Float
        temporalDescriptor.outputTextureFormat = .bgra8Unorm
        temporalDescriptor.inputWidth = width
        temporalDescriptor.inputHeight = height
        temporalDescriptor.outputWidth = width * 2
        temporalDescriptor.outputHeight = height * 2
        temporalDescriptor.isAutoExposureEnabled = true
        temporalDescriptor.isReactiveMaskTextureEnabled = true
        temporalDescriptor.reactiveMaskTextureFormat = .r8Unorm
        guard let temporalScaler = temporalDescriptor.makeTemporalScaler(
            device: device
        ) else {
            throw XCTSkip(
                "MetalFX temporal scaling is unavailable on this test host"
            )
        }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width * 2,
            height: height * 2,
            mipmapped: false
        )
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = temporalScaler.outputTextureUsage
        let temporalOutput = try XCTUnwrap(
            device.makeTexture(descriptor: outputDescriptor)
        )
        temporalScaler.colorTexture = secondFrame
        temporalScaler.depthTexture = secondOutput.depthTexture
        temporalScaler.motionTexture = secondOutput.motionTexture
        temporalScaler.reactiveMaskTexture = secondOutput.reactiveMaskTexture
        temporalScaler.outputTexture = temporalOutput
        temporalScaler.inputContentWidth = width
        temporalScaler.inputContentHeight = height
        temporalScaler.motionVectorScaleX = 1
        temporalScaler.motionVectorScaleY = 1
        temporalScaler.reset = true
        temporalScaler.encode(commandBuffer: secondCommandBuffer)

        let bytesPerRow = 256
        let motionReadback = try XCTUnwrap(
            device.makeBuffer(
                length: bytesPerRow * height,
                options: .storageModeShared
            )
        )
        let blit = try XCTUnwrap(secondCommandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: secondOutput.motionTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: motionReadback,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        secondCommandBuffer.commit()
        secondCommandBuffer.waitUntilCompleted()
        XCTAssertEqual(secondCommandBuffer.status, .completed)

        let sampleOffset = 32 * bytesPerRow + 32 * 4
        let motionPointer = motionReadback.contents().advanced(by: sampleOffset)
        let motionX = Float(
            Float16(bitPattern: motionPointer.load(as: UInt16.self))
        )
        let motionY = Float(
            Float16(
                bitPattern: motionPointer
                    .advanced(by: MemoryLayout<UInt16>.size)
                    .load(as: UInt16.self)
            )
        )

        // The current image moved right, so a current pixel maps back to a
        // location on its left in the previous image.
        XCTAssertLessThan(motionX, -1.5)
        XCTAssertLessThan(abs(motionY), 2.5)
    }

    func testProviderRejectsMotionAcrossAnAbruptSceneCut() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal is unavailable on this test host")
        }

        let width = 64
        let height = 64
        let provider = try DLSMTemporalReconstructionProvider(
            device: device,
            inputWidth: width,
            inputHeight: height
        )

        let darkFrame = try makeSolidTexture(
            device: device,
            width: width,
            height: height,
            value: 12
        )
        let firstCommandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        XCTAssertNotNil(
            provider.encode(
                sourceTexture: darkFrame,
                commandBuffer: firstCommandBuffer,
                resetHistory: true
            )
        )
        firstCommandBuffer.commit()
        firstCommandBuffer.waitUntilCompleted()
        XCTAssertEqual(firstCommandBuffer.status, .completed)

        let brightFrame = try makeSolidTexture(
            device: device,
            width: width,
            height: height,
            value: 240
        )
        let secondCommandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        let output = try XCTUnwrap(
            provider.encode(
                sourceTexture: brightFrame,
                commandBuffer: secondCommandBuffer,
                resetHistory: false
            )
        )

        let motionBytesPerRow = 256
        let motionReadback = try XCTUnwrap(
            device.makeBuffer(
                length: motionBytesPerRow * height,
                options: .storageModeShared
            )
        )
        let maskBytesPerRow = 256
        let maskReadback = try XCTUnwrap(
            device.makeBuffer(
                length: maskBytesPerRow * height,
                options: .storageModeShared
            )
        )
        let blit = try XCTUnwrap(secondCommandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: output.motionTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: motionReadback,
            destinationOffset: 0,
            destinationBytesPerRow: motionBytesPerRow,
            destinationBytesPerImage: motionBytesPerRow * height
        )
        blit.copy(
            from: output.reactiveMaskTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: maskReadback,
            destinationOffset: 0,
            destinationBytesPerRow: maskBytesPerRow,
            destinationBytesPerImage: maskBytesPerRow * height
        )
        blit.endEncoding()
        secondCommandBuffer.commit()
        secondCommandBuffer.waitUntilCompleted()
        XCTAssertEqual(secondCommandBuffer.status, .completed)

        let motionOffset = 32 * motionBytesPerRow + 32 * 4
        let motionPointer = motionReadback.contents().advanced(by: motionOffset)
        let motionX = Float(
            Float16(bitPattern: motionPointer.load(as: UInt16.self))
        )
        let motionY = Float(
            Float16(
                bitPattern: motionPointer
                    .advanced(by: MemoryLayout<UInt16>.size)
                    .load(as: UInt16.self)
            )
        )
        let reactiveValue = maskReadback.contents()
            .advanced(by: 32 * maskBytesPerRow + 32)
            .load(as: UInt8.self)

        XCTAssertLessThan(abs(motionX), 0.01)
        XCTAssertLessThan(abs(motionY), 0.01)
        XCTAssertGreaterThanOrEqual(reactiveValue, 250)
    }

    private func makeTexture(
        device: any MTLDevice,
        width: Int,
        height: Int,
        horizontalShift: Int
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

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sourceX = x - horizontalShift
                let value: UInt8
                if sourceX >= 0 {
                    value = UInt8(
                        truncatingIfNeeded:
                            sourceX &* 37 ^
                            y &* 73 ^
                            sourceX &* y &* 3
                    )
                } else {
                    value = 0
                }

                let offset = (y * width + x) * 4
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
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
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixel = [value, value, value, UInt8.max]
        let bytes = [UInt8](
            unsafeUninitializedCapacity: width * height * pixel.count
        ) { buffer, initializedCount in
            for offset in stride(from: 0, to: buffer.count, by: pixel.count) {
                buffer[offset] = pixel[0]
                buffer[offset + 1] = pixel[1]
                buffer[offset + 2] = pixel[2]
                buffer[offset + 3] = pixel[3]
            }
            initializedCount = buffer.count
        }
        bytes.withUnsafeBytes { rawBytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: rawBytes.baseAddress!,
                bytesPerRow: width * pixel.count
            )
        }
        return texture
    }
}
