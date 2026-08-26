import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import SemanticVersion

struct SolSemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    private let value: SemanticVersion
    let description: String

    init?(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = SemanticVersion(normalized) else { return nil }
        // Build metadata does not participate in precedence or Sol's release
        // identity. Dropping it also keeps `v0.2.0+4` equal to `0.2.0`.
        value = SemanticVersion(
            parsed.major,
            parsed.minor,
            parsed.patch,
            parsed.preRelease
        )
        description = value.description
    }

    static func < (lhs: SolSemanticVersion, rhs: SolSemanticVersion) -> Bool {
        lhs.value < rhs.value
    }
}

struct SolReleaseAsset: Decodable, Hashable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

struct SolRelease: Decodable, Hashable, Sendable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [SolReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }

    var version: SolSemanticVersion? { SolSemanticVersion(tagName) }

    var diskImage: SolReleaseAsset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    var diskImageChecksum: SolReleaseAsset? {
        guard let diskImage else { return nil }
        return assets.first { $0.name == diskImage.name + ".sha256" }
    }
}

enum SolUpdateState {
    case idle
    case checking
    case upToDate(Date)
    case available(SolRelease)
    case downloading(SolRelease)
    case ready(SolRelease, URL)
    case failed(String)
}

@MainActor
final class GitHubUpdateService: ObservableObject {
    static let repository = "Zinedinarnaut/Sol"
    private static let maximumDiskImageBytes = 1_500 * 1_024 * 1_024

    @Published private(set) var state: SolUpdateState = .idle

    private let session: URLSession
    private let fileManager: FileManager
    private let currentVersionProvider: () -> String
    private let logger = Logger(subsystem: "com.solemu.app", category: "Updates")

    init(
        session: URLSession? = nil,
        fileManager: FileManager = .default,
        currentVersionProvider: @escaping () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0.0.0"
        }
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        self.fileManager = fileManager
        self.currentVersionProvider = currentVersionProvider
    }

    var availableRelease: SolRelease? {
        switch state {
        case let .available(release), let .downloading(release), let .ready(release, _):
            return release
        default:
            return nil
        }
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    var readyDiskImage: URL? {
        if case let .ready(_, url) = state { return url }
        return nil
    }

    func checkForUpdates(force: Bool = false) async {
        if case .checking = state { return }
        if case .downloading = state { return }
        if !force, availableRelease != nil { return }

        guard let currentVersion = SolSemanticVersion(currentVersionProvider()),
              let endpoint = URL(
                string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=20"
              ) else {
            state = .failed("Sol could not read its installed version.")
            return
        }

        state = .checking
        do {
            var request = URLRequest(url: endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Sol/\(currentVersion.description)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            try Self.validateHTTPResponse(response, maximumBytes: 2 * 1_024 * 1_024, actualBytes: data.count)
            let releases = try JSONDecoder().decode([SolRelease].self, from: data)
            if let release = Self.newestDownloadableRelease(
                in: releases,
                newerThan: currentVersion
            ) {
                state = .available(release)
            } else {
                state = .upToDate(Date())
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Could not check GitHub for updates.")
        }
    }

    func downloadAvailableUpdate() async {
        guard let release = availableRelease,
              let diskImage = release.diskImage,
              let checksum = release.diskImageChecksum,
              diskImage.size > 0,
              diskImage.size <= Self.maximumDiskImageBytes else {
            state = .failed("This release does not include a verified macOS download.")
            return
        }

        state = .downloading(release)
        do {
            async let imageDownload = session.download(from: diskImage.browserDownloadURL)
            async let checksumDownload = session.data(from: checksum.browserDownloadURL)
            let ((temporaryURL, imageResponse), (checksumData, checksumResponse)) = try await (
                imageDownload,
                checksumDownload
            )

            try Self.validateDownloadResponse(
                imageResponse,
                expectedMaximumBytes: Self.maximumDiskImageBytes
            )
            try Self.validateDownloadResponse(
                checksumResponse,
                expectedMaximumBytes: 8 * 1_024
            )
            guard checksumData.count <= 8 * 1_024 else {
                throw UpdateError.invalidResponse
            }
            guard let expectedChecksum = Self.parseChecksum(checksumData) else {
                throw UpdateError.invalidChecksum
            }

            let updateDirectory = try updateCacheDirectory()
            let finalURL = updateDirectory.appendingPathComponent(diskImage.name, isDirectory: false)
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            guard let downloadedSize = try finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  downloadedSize == diskImage.size,
                  downloadedSize <= Self.maximumDiskImageBytes else {
                try? fileManager.removeItem(at: finalURL)
                throw UpdateError.invalidResponse
            }

            let actualChecksum = try await Task.detached(priority: .utility) {
                try Self.sha256(of: finalURL)
            }.value
            guard actualChecksum == expectedChecksum else {
                try? fileManager.removeItem(at: finalURL)
                throw UpdateError.checksumMismatch
            }

            state = .ready(release, finalURL)
            NSWorkspace.shared.open(finalURL)
        } catch {
            logger.error("Update download failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("The update could not be downloaded and verified.")
        }
    }

    func openReadyUpdate() {
        if let readyDiskImage {
            NSWorkspace.shared.open(readyDiskImage)
        } else if let release = availableRelease {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    func openReleasePage() {
        guard let release = availableRelease else { return }
        NSWorkspace.shared.open(release.htmlURL)
    }

    static func newestDownloadableRelease(
        in releases: [SolRelease],
        newerThan currentVersion: SolSemanticVersion
    ) -> SolRelease? {
        releases
            .filter { !$0.draft && $0.diskImage != nil && $0.diskImageChecksum != nil }
            .filter { ($0.version ?? currentVersion) > currentVersion }
            .max { ($0.version ?? currentVersion) < ($1.version ?? currentVersion) }
    }

    static func parseChecksum(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased(),
              value.count == 64,
              value.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return value
    }

    private func updateCacheDirectory() throws -> URL {
        guard let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw UpdateError.missingCacheDirectory
        }
        let directory = base
            .appendingPathComponent("com.solemu.app", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func validateHTTPResponse(
        _ response: URLResponse,
        maximumBytes: Int,
        actualBytes: Int
    ) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              actualBytes <= maximumBytes else {
            throw UpdateError.invalidResponse
        }
    }

    private static func validateDownloadResponse(
        _ response: URLResponse,
        expectedMaximumBytes: Int
    ) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let url = http.url,
              isTrustedGitHubDownload(url),
              http.expectedContentLength <= 0 ||
                http.expectedContentLength <= Int64(expectedMaximumBytes) else {
            throw UpdateError.invalidResponse
        }
    }

    private static func isTrustedGitHubDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" ||
            host.hasSuffix(".github.com") ||
            host.hasSuffix(".githubusercontent.com")
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse
        case invalidChecksum
        case checksumMismatch
        case missingCacheDirectory
    }
}
