import AppKit
import Foundation
import XCTest
@testable import Sol

final class ImageCacheTests: XCTestCase {
    func testInvalidImageDataIsNotPersisted() {
        let key = "invalid-image-\(UUID().uuidString)"
        defer { ImageCache.shared.remove(forKey: key) }

        let stored = ImageCache.shared.store(
            data: Data("this is not an image".utf8),
            forKey: key,
            fileExtension: "png"
        )

        XCTAssertNil(stored)
        XCTAssertNil(ImageCache.shared.imageData(forKey: key))
    }

    func testMemoryTrimPreservesDiskArtwork() throws {
        let key = "memory-trim-\(UUID().uuidString)"
        defer { ImageCache.shared.remove(forKey: key) }

        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let data = try XCTUnwrap(
            representation?.representation(using: .png, properties: [:])
        )
        XCTAssertNotNil(
            ImageCache.shared.store(
                data: data,
                forKey: key,
                fileExtension: "png"
            )
        )

        ImageCache.shared.trimMemory()

        XCTAssertEqual(ImageCache.shared.imageData(forKey: key), data)
        XCTAssertNotNil(ImageCache.shared.image(forKey: key))
    }
}
