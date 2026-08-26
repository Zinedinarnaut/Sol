import Foundation
import AppKit
import ImageIO

actor ThumbnailService {
    private let cache = ImageCache.shared
    private let session: URLSession
    private static let maximumImageBytes = 25 * 1_024 * 1_024

    private enum BackgroundValidation {
        static let minWidth: CGFloat = 1_000
        static let minHeight: CGFloat = 500
        static let minAspect: CGFloat = 1.6
        static let maxAspect: CGFloat = 2.4
    }

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            configuration.urlCache = URLCache(
                memoryCapacity: 8 * 1_024 * 1_024,
                diskCapacity: 64 * 1_024 * 1_024
            )
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetchThumbnail(for game: Game, targetPixelSize: Int? = nil) async -> NSImage? {
        let cacheKey = game.titleId ?? game.title
        if let targetPixelSize, let scaled = cache.scaledImage(forKey: cacheKey, maxPixelSize: targetPixelSize) {
            return scaled
        }
        if let cached = cache.image(forKey: cacheKey) {
            return cached
        }

        if let titleId = game.titleId {
            if let image = await fetchFromNlib(
                titleId: titleId,
                cacheKey: cacheKey,
                preferBanner: false,
                targetPixelSize: targetPixelSize
            ) {
                return image
            }
        }

        if let image = await fetchFromPlatformSearch(
            game: game,
            cacheKey: cacheKey,
            preferWide: false,
            targetPixelSize: targetPixelSize
        ) {
            return image
        }

        return nil
    }

    func fetchBackground(
        for game: Game,
        targetPixelSize: Int? = nil
    ) async -> NSImage? {
        let artworkKey = game.titleId ?? game.title
        let cacheKey = artworkKey + ":bg-v\(backgroundCacheVersion())"
        if let data = cache.imageData(forKey: cacheKey) {
            if isValidBackground(data) {
                if let targetPixelSize,
                   let scaled = cache.scaledImage(
                       forKey: cacheKey,
                       maxPixelSize: targetPixelSize
                   ) {
                    return scaled
                }
                return NSImage(data: data)
            } else {
                cache.remove(forKey: cacheKey)
            }
        }

        // The platform artwork provider is primary. Nlib remains a fallback
        // because it can provide banners for titles the primary source misses.
        if let image = await fetchFromPlatformSearch(
            game: game,
            cacheKey: cacheKey,
            preferWide: true,
            validateBackground: true,
            targetPixelSize: targetPixelSize
        ) {
            return image
        }

        if let titleId = game.titleId {
            if let image = await fetchFromNlib(
                titleId: titleId,
                cacheKey: cacheKey,
                preferBanner: true,
                validateBackground: true,
                targetPixelSize: targetPixelSize
            ) {
                return image
            }
        }

        // A blurred cover is preferable to dropping back to a blank theme.
        if let cachedCover = cache.image(forKey: artworkKey) {
            return cachedCover
        }

        return await fetchThumbnail(for: game, targetPixelSize: targetPixelSize)
    }

    private func backgroundCacheVersion() -> Int {
        let stored = UserDefaults.standard.integer(forKey: "backgroundCacheVersion")
        return max(stored, 2)
    }

    private func fetchFromNlib(
        titleId: String,
        cacheKey: String,
        preferBanner: Bool,
        validateBackground: Bool = false,
        targetPixelSize: Int? = nil
    ) async -> NSImage? {
        guard let url = URL(string: "https://api.nlib.cc/nx/\(titleId)?fields=name,icon,banner") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let info = try? JSONDecoder().decode(NlibGameResponse.self, from: data) else { return nil }

            if preferBanner {
                if let bannerURLString = info.banner, let bannerURL = secureURL(from: bannerURLString) {
                    return await fetchImageData(
                        from: bannerURL,
                        cacheKey: cacheKey,
                        validateBackground: validateBackground,
                        targetPixelSize: targetPixelSize
                    )
                }
            } else {
                if let iconURLString = info.icon, let iconURL = secureURL(from: iconURLString) {
                    return await fetchImageData(
                        from: iconURL,
                        cacheKey: cacheKey,
                        targetPixelSize: targetPixelSize
                    )
                }
                if let bannerURLString = info.banner, let bannerURL = secureURL(from: bannerURLString) {
                    return await fetchImageData(
                        from: bannerURL,
                        cacheKey: cacheKey,
                        targetPixelSize: targetPixelSize
                    )
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func fetchFromPlatformSearch(
        game: Game,
        cacheKey: String,
        preferWide: Bool,
        validateBackground: Bool = false,
        targetPixelSize: Int? = nil
    ) async -> NSImage? {
        guard let url = platformSearchURL(query: game.title) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let result = try? JSONDecoder().decode(PlatformSearchResponse.self, from: data) else { return nil }
            guard let doc = bestPlatformDocument(in: result.response.docs, for: game) else {
                return nil
            }

            let candidates: [String?]
            if preferWide {
                candidates = [
                    doc.imageWideURLHighRes,
                    doc.wishlistBanner640URL,
                    doc.image16x9URL,
                    doc.imageWideURL,
                    doc.wishlistBanner460URL
                ]
            } else {
                candidates = [
                    doc.imageURL,
                    doc.imageSquareURL,
                    doc.imageWideURL,
                    doc.image16x9URL
                ]
            }

            var attemptedURLs = Set<URL>()
            for candidate in candidates {
                guard let candidate else { continue }
                let candidateURLs = preferWide
                    ? wideArtworkURLs(from: candidate)
                    : [secureURL(from: candidate)].compactMap { $0 }

                for imageURL in candidateURLs
                where attemptedURLs.insert(imageURL).inserted {
                    if let image = await fetchImageData(
                        from: imageURL,
                        cacheKey: cacheKey,
                        validateBackground: validateBackground,
                        targetPixelSize: targetPixelSize
                    ) {
                        return image
                    }
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func fetchImageData(
        from url: URL,
        cacheKey: String,
        validateBackground: Bool = false,
        targetPixelSize: Int? = nil
    ) async -> NSImage? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard !data.isEmpty, data.count <= Self.maximumImageBytes else { return nil }
            if validateBackground, !isValidBackground(data) {
                return nil
            }
            let fileExt = fileExtension(from: http, url: url)
            guard let image = cache.store(
                data: data,
                forKey: cacheKey,
                fileExtension: fileExt,
                memoryMaxPixelSize: targetPixelSize
            ) else {
                return nil
            }
            SharedThumbnailStore.shared.store(data: data, key: cacheKey, fileExtension: fileExt)
            return image
        } catch {
            return nil
        }
    }

    private func isValidBackground(_ data: Data) -> Bool {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return false }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return false
        }
        let aspect = width / max(height, 1)
        if width < BackgroundValidation.minWidth || height < BackgroundValidation.minHeight {
            return false
        }
        if aspect < BackgroundValidation.minAspect || aspect > BackgroundValidation.maxAspect {
            return false
        }
        return true
    }

    private func secureURL(from urlString: String) -> URL? {
        var components = URLComponents(string: urlString)
        if components?.scheme?.lowercased() == "http" {
            components?.scheme = "https"
        }
        guard components?.scheme?.lowercased() == "https" else { return nil }
        return components?.url
    }

    private func wideArtworkURLs(from urlString: String) -> [URL] {
        guard let sourceURL = secureURL(from: urlString) else { return [] }
        guard sourceURL.host?.hasSuffix("nintendo.com") == true else {
            return [sourceURL]
        }

        let sourcePath = sourceURL.path
        let originalPath = sourcePath.replacingOccurrences(
            of: "_image[0-9]+w(?=\\.[A-Za-z0-9]+$)",
            with: "",
            options: .regularExpression
        )
        guard originalPath != sourcePath else {
            return [sourceURL]
        }

        let mediumPath = sourcePath.replacingOccurrences(
            of: "_image[0-9]+w(?=\\.[A-Za-z0-9]+$)",
            with: "_image1600w",
            options: .regularExpression
        )
        var urls: [URL] = []
        for path in [originalPath, mediumPath, sourcePath] {
            var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
            components?.path = path
            if let url = components?.url, !urls.contains(url) {
                urls.append(url)
            }
        }
        return urls
    }

    private func fileExtension(from response: HTTPURLResponse, url: URL) -> String {
        if let mime = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if mime.contains("png") { return "png" }
            if mime.contains("jpeg") || mime.contains("jpg") { return "jpg" }
            if mime.contains("webp") { return "webp" }
        }
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp"].contains(ext) ? (ext == "jpeg" ? "jpg" : ext) : "jpg"
    }

    private func platformSearchURL(query: String) -> URL? {
        var components = URLComponents(string: "https://search.nintendo-europe.com/en/select")
        let fq = "type:GAME AND system_type:nintendoswitch*"
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fq", value: fq),
            URLQueryItem(name: "rows", value: "8"),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "wt", value: "json")
        ]
        return components?.url
    }

    private func bestPlatformDocument(
        in documents: [PlatformSearchDoc],
        for game: Game
    ) -> PlatformSearchDoc? {
        guard !documents.isEmpty else { return nil }

        if let titleID = game.titleId?.lowercased(),
           let exactIDMatch = documents.first(where: {
               $0.applicationID?.lowercased() == titleID
           }) {
            return exactIDMatch
        }

        let requestedTitle = Self.normalizedArtworkTitle(game.title)
        if let exactTitleMatch = documents.first(where: {
            guard let title = $0.title else { return false }
            return Self.normalizedArtworkTitle(title) == requestedTitle
        }) {
            return exactTitleMatch
        }

        let requestedTokens = Set(requestedTitle.split(separator: " ").map(String.init))
        let scored = documents.compactMap { document -> (PlatformSearchDoc, Double)? in
            guard let title = document.title else { return nil }
            let candidateTokens = Set(
                Self.normalizedArtworkTitle(title).split(separator: " ").map(String.init)
            )
            guard !requestedTokens.isEmpty, !candidateTokens.isEmpty else { return nil }
            let shared = requestedTokens.intersection(candidateTokens).count
            let union = requestedTokens.union(candidateTokens).count
            return (document, Double(shared) / Double(union))
        }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.72 {
            return best.0
        }

        // Older mocked/provider responses may omit identity fields. Keep that
        // compatible fallback only when there is nothing meaningful to score.
        return documents.allSatisfy { $0.title == nil && $0.applicationID == nil }
            ? documents.first
            : nil
    }

    private static func normalizedArtworkTitle(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private struct NlibGameResponse: Decodable {
    let id: String?
    let name: String?
    let icon: String?
    let banner: String?
}

private struct PlatformSearchResponse: Decodable {
    let response: PlatformSearchDocs
}

private struct PlatformSearchDocs: Decodable {
    let docs: [PlatformSearchDoc]
}

private struct PlatformSearchDoc: Decodable {
    let title: String?
    let applicationID: String?
    let imageURL: String?
    let imageSquareURL: String?
    let imageWideURL: String?
    let imageWideURLHighRes: String?
    let image16x9URL: String?
    let wishlistBanner640URL: String?
    let wishlistBanner460URL: String?

    enum CodingKeys: String, CodingKey {
        case title
        case applicationID = "application_id_s"
        case imageURL = "image_url"
        case imageSquareURL = "image_url_sq_s"
        case imageWideURL = "image_url_h2x1_s"
        case imageWideURLHighRes = "image_url_h2x1"
        case image16x9URL = "image_url_h16x9_s"
        case wishlistBanner640URL = "wishlist_email_banner640w_image_url_s"
        case wishlistBanner460URL = "wishlist_email_banner460w_image_url_s"
    }
}
