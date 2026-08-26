import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Sol

@MainActor
final class SolProfileImageStoreTests: XCTestCase {
    func testPreparesSquareMetadataFreePNGAndPersistsByRevision() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.jpg")
        try makeSourceImage(width: 160, height: 90).write(to: sourceURL)
        let imageRoot = root.appendingPathComponent("avatars", isDirectory: true)
        let store = SolProfileImageStore(rootURL: imageRoot)

        let prepared = try SolProfileImageStore.prepareImageData(from: sourceURL)
        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithData(prepared as CFData, nil)
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any]
        )

        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.png.identifier)
        XCTAssertEqual(
            properties[kCGImagePropertyPixelWidth] as? Int,
            SolProfileImageStore.outputDimension
        )
        XCTAssertEqual(
            properties[kCGImagePropertyPixelHeight] as? Int,
            SolProfileImageStore.outputDimension
        )
        let exif = properties[kCGImagePropertyExifDictionary]
            as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])

        let profileID = UUID()
        let revision = try store.savePreparedImage(
            prepared,
            profileID: profileID
        )

        XCTAssertTrue(store.containsImage(profileID: profileID, revision: revision))
        XCTAssertNotNil(store.image(profileID: profileID, revision: revision))

        try store.removeImage(profileID: profileID, revision: revision)
        XCTAssertFalse(store.containsImage(profileID: profileID, revision: revision))
    }

    func testRejectsAFileThatIsNotAnImage() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("not-an-image.txt")
        try Data("hello".utf8).write(to: sourceURL)

        XCTAssertThrowsError(
            try SolProfileImageStore.prepareImageData(from: sourceURL)
        ) { error in
            XCTAssertEqual(
                error as? SolProfileImageStoreError,
                .unsupportedImage
            )
        }
    }

    private func makeSourceImage(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(red: 0.15, green: 0.35, blue: 0.85, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(
            CGColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1)
        )
        context.fill(
            CGRect(
                x: width / 4,
                y: 0,
                width: width / 2,
                height: height
            )
        )

        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.9,
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: "private-source-metadata",
                ],
            ] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
