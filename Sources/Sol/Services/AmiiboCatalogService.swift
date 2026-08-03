import Foundation

actor AmiiboCatalogService {
    static let shared = AmiiboCatalogService()

    private static let catalogURL = URL(string: "https://amiiboapi.org/api/amiibo/")!
    private static let compatibilityURL = URL(
        string: "https://raw.githubusercontent.com/Ryubing/Nfc/refs/heads/main/tags.json"
    )!
    private static let maximumResponseBytes = 8 * 1_024 * 1_024
    private static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    private let session: URLSession
    private let cacheURL: URL

    init(session: URLSession? = nil, cacheURL: URL? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 45
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }

        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = cacheURL
            ?? caches
                .appendingPathComponent("Sol/Amiibo", isDirectory: true)
                .appendingPathComponent("catalog-v2.json")
    }

    func catalog(forceRefresh: Bool = false) async throws -> [AmiiboCatalogItem] {
        if !forceRefresh, let cached = loadCache(requireFresh: true) {
            return cached
        }

        do {
            async let catalogData = fetch(Self.catalogURL)
            async let compatibilityData = fetchCompatibility()
            let items = try Self.decodeCatalog(
                apiData: await catalogData,
                compatibilityData: await compatibilityData
            )
            storeCache(items)
            return items
        } catch {
            if let cached = loadCache(requireFresh: false) {
                return cached
            }
            throw error
        }
    }

    static func decodeCatalog(
        apiData: Data,
        compatibilityData: Data?
    ) throws -> [AmiiboCatalogItem] {
        let decoder = JSONDecoder()
        let response = try decoder.decode(AmiiboAPIResponse.self, from: apiData)
        let compatibility = compatibilityData.flatMap {
            try? decoder.decode(RyubingAmiiboResponse.self, from: $0)
        }
        var titleIDsByScanID: [String: Set<String>] = [:]

        for item in compatibility?.amiibo ?? [] {
            let scanID = (item.head + item.tail).uppercased()
            let titleIDs = item.gamesSwitch
                .flatMap(\.gameID)
                .map { $0.uppercased() }
            titleIDsByScanID[scanID, default: []].formUnion(titleIDs)
        }

        var seenIDs = Set<String>()
        return response.amiibo.compactMap { item in
            let scanID = (item.head + item.tail).uppercased()
            guard scanID.count == 16,
                  scanID.allSatisfy(\.isHexDigit) else {
                return nil
            }

            let variant = item.variant?.uppercased() ?? ""
            let id = variant.isEmpty ? scanID : "\(scanID)-\(variant)"
            guard seenIDs.insert(id).inserted else { return nil }

            return AmiiboCatalogItem(
                id: id,
                scanID: scanID,
                name: item.name,
                character: item.character,
                gameSeries: item.gameSeries,
                amiiboSeries: item.amiiboSeries,
                type: item.type,
                imageURL: secureURL(item.image),
                compatibleTitleIDs: titleIDsByScanID[scanID] ?? []
            )
        }
        .sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func fetchCompatibility() async -> Data? {
        try? await fetch(Self.compatibilityURL)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CatalogError.invalidResponse
        }
        guard !data.isEmpty, data.count <= Self.maximumResponseBytes else {
            throw CatalogError.invalidResponse
        }
        return data
    }

    private func loadCache(requireFresh: Bool) -> [AmiiboCatalogItem]? {
        if requireFresh {
            guard let values = try? cacheURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ),
            let modified = values.contentModificationDate,
            Date().timeIntervalSince(modified) <= Self.cacheLifetime else {
                return nil
            }
        }
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode([AmiiboCatalogItem].self, from: data)
    }

    private func storeCache(_ items: [AmiiboCatalogItem]) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(items)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            return
        }
    }

    private static func secureURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }

    enum CatalogError: LocalizedError {
        case invalidResponse

        var errorDescription: String? {
            "The Amiibo catalog returned an invalid response."
        }
    }
}

private struct AmiiboAPIResponse: Decodable {
    let amiibo: [AmiiboAPIItem]
}

private struct AmiiboAPIItem: Decodable {
    let amiiboSeries: String
    let character: String
    let gameSeries: String
    let head: String
    let image: String
    let name: String
    let tail: String
    let type: String
    let variant: String?
}

private struct RyubingAmiiboResponse: Decodable {
    let amiibo: [RyubingAmiiboItem]
}

private struct RyubingAmiiboItem: Decodable {
    let head: String
    let tail: String
    let gamesSwitch: [RyubingSwitchGame]
}

private struct RyubingSwitchGame: Decodable {
    let gameID: [String]
}
