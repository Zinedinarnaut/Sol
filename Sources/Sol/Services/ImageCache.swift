import Foundation
import AppKit
import CryptoKit
import ImageIO

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let lock = NSLock()
    private var scaledKeysByBaseKey: [String: Set<NSString>] = [:]

    private init() {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("Sol/Covers", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Sol/Covers", isDirectory: true)
        cacheDirectory = dir

        if let base {
            let legacyDirectory = base.appendingPathComponent("RyjinxLauncher/Covers", isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path),
               fileManager.fileExists(atPath: legacyDirectory.path) {
                try? fileManager.createDirectory(
                    at: dir.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fileManager.moveItem(at: legacyDirectory, to: dir)
            }
        }

        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func image(forKey key: String) -> NSImage? {
        synchronized {
            if let cached = memoryCache.object(forKey: key as NSString) {
                return cached
            }
            for (data, ext) in cachedDataCandidates(forKey: key) {
                if let image = NSImage(data: data) {
                    memoryCache.setObject(image, forKey: key as NSString)
                    SharedThumbnailStore.shared.store(data: data, key: key, fileExtension: ext)
                    return image
                }
            }
            return nil
        }
    }

    func scaledImage(forKey key: String, maxPixelSize: Int) -> NSImage? {
        synchronized {
            let cacheKey = "\(key)#\(maxPixelSize)" as NSString
            if let cached = memoryCache.object(forKey: cacheKey) {
                return cached
            }
            guard let data = cachedDataCandidates(forKey: key).first?.data,
                  let thumbnail = Self.createThumbnail(from: data, maxPixelSize: maxPixelSize) else {
                return nil
            }
            memoryCache.setObject(thumbnail, forKey: cacheKey)
            scaledKeysByBaseKey[key, default: []].insert(cacheKey)
            return thumbnail
        }
    }

    func imageData(forKey key: String) -> Data? {
        synchronized {
            cachedDataCandidates(forKey: key).first?.data
        }
    }

    func remove(forKey key: String) {
        synchronized {
            removeMemoryEntries(forKey: key)
            removeDiskEntries(forKey: key)
        }
    }

    @discardableResult
    func store(data: Data, forKey key: String, fileExtension: String) -> NSImage? {
        synchronized {
            guard let image = NSImage(data: data) else { return nil }
            let safeExtension = Self.sanitizedExtension(fileExtension)
            let fileURL = cacheFileURL(forKey: key, fileExtension: safeExtension)
            do {
                removeMemoryEntries(forKey: key)
                removeDiskEntries(forKey: key)
                try data.write(to: fileURL, options: .atomic)
                memoryCache.setObject(image, forKey: key as NSString)
                return image
            } catch {
                return nil
            }
        }
    }

    func clearAll() {
        synchronized {
            memoryCache.removeAllObjects()
            scaledKeysByBaseKey.removeAll()
            do {
                if fileManager.fileExists(atPath: cacheDirectory.path) {
                    try fileManager.removeItem(at: cacheDirectory)
                }
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            } catch {
                return
            }
        }
    }

    private func cacheFileURL(forKey key: String, fileExtension: String = "jpg") -> URL {
        let hashed = Self.hash(key)
        return cacheDirectory.appendingPathComponent(hashed).appendingPathExtension(fileExtension)
    }

    private func cachedDataCandidates(forKey key: String) -> [(data: Data, fileExtension: String)] {
        let hashed = Self.hash(key)
        return Self.supportedExtensions.compactMap { ext in
            let fileURL = cacheDirectory.appendingPathComponent(hashed).appendingPathExtension(ext)
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return (data, ext)
        }
    }

    private func removeMemoryEntries(forKey key: String) {
        memoryCache.removeObject(forKey: key as NSString)
        for scaledKey in scaledKeysByBaseKey.removeValue(forKey: key) ?? [] {
            memoryCache.removeObject(forKey: scaledKey)
        }
    }

    private func removeDiskEntries(forKey key: String) {
        let hashed = Self.hash(key)
        for ext in Self.supportedExtensions {
            let fileURL = cacheDirectory.appendingPathComponent(hashed).appendingPathExtension(ext)
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func synchronized<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private static let supportedExtensions = ["jpg", "png", "webp"]

    private static func sanitizedExtension(_ value: String) -> String {
        let normalized = value.lowercased()
        return supportedExtensions.contains(normalized) ? normalized : "jpg"
    }

    private static func hash(_ value: String) -> String {
        let data = Data(value.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func createThumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        let originalMax = max(width, height)
        let targetMax = min(CGFloat(maxPixelSize), originalMax)

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(targetMax)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
