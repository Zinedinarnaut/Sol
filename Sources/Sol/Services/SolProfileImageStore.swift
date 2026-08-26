import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SolProfileImageStoreError: LocalizedError, Equatable, Sendable {
    case fileTooLarge
    case unsupportedImage
    case imageCouldNotBeProcessed

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "Choose an image smaller than 25 MB."
        case .unsupportedImage:
            "That file is not a supported image."
        case .imageCouldNotBeProcessed:
            "Sol could not prepare that image. Try a PNG, JPEG, HEIC, or WebP file."
        }
    }
}

@MainActor
final class SolProfileImageStore {
    static let shared = SolProfileImageStore()

    nonisolated static let outputDimension = 1_024
    nonisolated static let maximumInputBytes = 25 * 1_024 * 1_024

    private let rootURL: URL
    private let fileManager: FileManager
    private let cache = NSCache<NSString, NSImage>()

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    /// Reads a user-selected image, applies orientation, center-crops it to a
    /// square, resizes it, and writes a fresh PNG without source metadata.
    nonisolated static func prepareImageData(from sourceURL: URL) throws -> Data {
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        if let fileSize = try? sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize,
           fileSize > Self.maximumInputBytes {
            throw SolProfileImageStoreError.fileTooLarge
        }

        let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard sourceData.count <= Self.maximumInputBytes else {
            throw SolProfileImageStoreError.fileTooLarge
        }
        guard let imageSource = CGImageSourceCreateWithData(
            sourceData as CFData,
            nil
        ),
              CGImageSourceGetCount(imageSource) > 0,
              let sourceType = CGImageSourceGetType(imageSource),
              UTType(sourceType as String)?.conforms(to: .image) == true else {
            throw SolProfileImageStoreError.unsupportedImage
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.outputDimension * 2,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw SolProfileImageStoreError.imageCouldNotBeProcessed
        }

        return try makeSquarePNG(from: thumbnail)
    }

    func savePreparedImage(
        _ data: Data,
        profileID: UUID
    ) throws -> UUID {
        try validatePreparedImage(data)
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let revision = UUID()
        let destination = imageURL(profileID: profileID, revision: revision)
        try data.write(to: destination, options: .atomic)

        if let image = NSImage(data: data) {
            cache.setObject(
                image,
                forKey: cacheKey(profileID: profileID, revision: revision),
                cost: data.count
            )
        }
        return revision
    }

    func image(
        profileID: UUID,
        revision: UUID
    ) -> NSImage? {
        let key = cacheKey(profileID: profileID, revision: revision)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let url = imageURL(profileID: profileID, revision: revision)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let image = NSImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    func removeImage(
        profileID: UUID,
        revision: UUID
    ) throws {
        cache.removeObject(
            forKey: cacheKey(profileID: profileID, revision: revision)
        )
        let url = imageURL(profileID: profileID, revision: revision)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func containsImage(
        profileID: UUID,
        revision: UUID
    ) -> Bool {
        image(profileID: profileID, revision: revision) != nil
    }

    nonisolated private static func makeSquarePNG(
        from image: CGImage
    ) throws -> Data {
        let side = min(image.width, image.height)
        let cropRect = CGRect(
            x: (image.width - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        guard let croppedImage = image.cropping(to: cropRect),
              let context = CGContext(
                  data: nil,
                  width: Self.outputDimension,
                  height: Self.outputDimension,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)
                      ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw SolProfileImageStoreError.imageCouldNotBeProcessed
        }

        context.interpolationQuality = .high
        context.draw(
            croppedImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: Self.outputDimension,
                height: Self.outputDimension
            )
        )
        guard let renderedImage = context.makeImage() else {
            throw SolProfileImageStoreError.imageCouldNotBeProcessed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw SolProfileImageStoreError.imageCouldNotBeProcessed
        }
        CGImageDestinationAddImage(destination, renderedImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SolProfileImageStoreError.imageCouldNotBeProcessed
        }
        return output as Data
    }

    private func validatePreparedImage(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == Self.outputDimension,
              height == Self.outputDimension else {
            throw SolProfileImageStoreError.imageCouldNotBeProcessed
        }
    }

    private func imageURL(
        profileID: UUID,
        revision: UUID
    ) -> URL {
        rootURL.appendingPathComponent(
            "\(profileID.uuidString.lowercased())-\(revision.uuidString.lowercased()).png",
            isDirectory: false
        )
    }

    private func cacheKey(
        profileID: UUID,
        revision: UUID
    ) -> NSString {
        "\(profileID.uuidString)-\(revision.uuidString)" as NSString
    }

    nonisolated private static func defaultRootURL(
        fileManager: FileManager
    ) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Sol", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent("Avatars", isDirectory: true)
    }
}
