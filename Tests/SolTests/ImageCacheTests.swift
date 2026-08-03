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
}
