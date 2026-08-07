import Foundation
import Combine
import ServiceManagement
import SolDLSM

final class SettingsStore: ObservableObject {
    private static let minimumBackgroundCacheVersion = 2
    private static let backgroundArtworkQualitySchema = 1
    private static let legacyBundleIdentifiers = [
        "com.sol.app",
        "com.ryjinx.launcher",
    ]
    @Published var gamesDirectory: String {
        didSet { UserDefaults.standard.set(gamesDirectory, forKey: Keys.gamesDirectory) }
    }

    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    @Published var backgroundCacheVersion: Int {
        didSet { UserDefaults.standard.set(backgroundCacheVersion, forKey: Keys.backgroundCacheVersion) }
    }

    @Published var dlsmMode: DLSMMode {
        didSet { UserDefaults.standard.set(dlsmMode.rawValue, forKey: Keys.dlsmMode) }
    }

    @Published var dlsmQuality: DLSMQuality {
        didSet { UserDefaults.standard.set(dlsmQuality.rawValue, forKey: Keys.dlsmQuality) }
    }

    @Published var dlsmFrameGeneration: Bool {
        didSet { UserDefaults.standard.set(dlsmFrameGeneration, forKey: Keys.dlsmFrameGeneration) }
    }

    var dlsmConfiguration: DLSMConfiguration {
        let requested = DLSMConfiguration(
            mode: dlsmMode,
            quality: dlsmQuality,
            frameGeneration: dlsmFrameGeneration
        )

        guard DLSMFeatureGate.isEnabled else {
            return DLSMFeatureGate.disabledConfiguration(preserving: requested)
        }

        return DLSMFeatureGate.resolvedConfiguration(
            requested,
            capabilities: .current
        )
    }

    init() {
        Self.migrateLegacyDefaultsIfNeeded()

        self.gamesDirectory = UserDefaults.standard.string(forKey: Keys.gamesDirectory) ?? ""
        let storedLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
        self.launchAtLogin = storedLogin
        let defaults = UserDefaults.standard
        let storedVersion = defaults.integer(forKey: Keys.backgroundCacheVersion)
        let resolvedBackgroundCacheVersion = Self.resolvedBackgroundCacheVersion(
            storedVersion: storedVersion,
            hadStoredVersion: defaults.object(forKey: Keys.backgroundCacheVersion) != nil,
            storedQualitySchema: defaults.integer(forKey: Keys.backgroundArtworkQualitySchema)
        )
        self.backgroundCacheVersion = resolvedBackgroundCacheVersion
        defaults.set(resolvedBackgroundCacheVersion, forKey: Keys.backgroundCacheVersion)
        defaults.set(
            Self.backgroundArtworkQualitySchema,
            forKey: Keys.backgroundArtworkQualitySchema
        )
        let requestedDLSM = DLSMConfiguration(
            mode: DLSMMode(
                rawValue: UserDefaults.standard.string(forKey: Keys.dlsmMode) ?? ""
            ) ?? .off,
            quality: DLSMQuality(
                rawValue: UserDefaults.standard.string(forKey: Keys.dlsmQuality) ?? ""
            ) ?? .quality,
            frameGeneration: UserDefaults.standard.bool(
                forKey: Keys.dlsmFrameGeneration
            )
        )
        let resolvedDLSM = requestedDLSM.resolved(for: .current)
        self.dlsmMode = resolvedDLSM.mode
        self.dlsmQuality = resolvedDLSM.quality
        self.dlsmFrameGeneration = resolvedDLSM.frameGeneration

        if resolvedDLSM != requestedDLSM {
            UserDefaults.standard.set(resolvedDLSM.mode.rawValue, forKey: Keys.dlsmMode)
            UserDefaults.standard.set(
                resolvedDLSM.frameGeneration,
                forKey: Keys.dlsmFrameGeneration
            )
        }

        applyLoginItemSetting(launchAtLogin)
    }

    private enum Keys {
        static let gamesDirectory = "gamesDirectory"
        static let gamesDirectoryBookmark = "gamesDirectoryBookmark"
        static let launchAtLogin = "launchAtLogin"
        static let backgroundCacheVersion = "backgroundCacheVersion"
        static let backgroundArtworkQualitySchema = "backgroundArtworkQualitySchema"
        static let dlsmMode = "dlsmMode"
        static let dlsmQuality = "dlsmQuality"
        static let dlsmFrameGeneration = "dlsmFrameGeneration"
        static let legacyMigrationComplete = "solLegacyPreferencesMigrationComplete"
    }

    private static func migrateLegacyDefaultsIfNeeded() {
        let current = UserDefaults.standard
        guard !current.bool(forKey: Keys.legacyMigrationComplete) else { return }

        let migratedKeys = [
            Keys.gamesDirectory,
            Keys.launchAtLogin,
            Keys.backgroundCacheVersion,
            Keys.dlsmMode,
            Keys.dlsmQuality,
            Keys.dlsmFrameGeneration,
        ]

        for legacyBundleIdentifier in legacyBundleIdentifiers {
            if let legacy = UserDefaults(suiteName: legacyBundleIdentifier) {
                for key in migratedKeys
                where current.object(forKey: key) == nil {
                    if let value = legacy.object(forKey: key) {
                        current.set(value, forKey: key)
                    }
                }
            }
        }

        current.set(true, forKey: Keys.legacyMigrationComplete)
    }

    enum BookmarkKind {
        case games
    }

    struct ScopedAccess {
        let url: URL
        let stop: () -> Void
    }

    func storeBookmark(for kind: BookmarkKind, url: URL) {
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        do {
            let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey(for: kind))
        } catch {
            return
        }
    }

    func bumpBackgroundCacheVersion() {
        backgroundCacheVersion &+= 1
    }

    static func resolvedBackgroundCacheVersion(
        storedVersion: Int,
        hadStoredVersion: Bool,
        storedQualitySchema: Int
    ) -> Int {
        let needsHighResolutionRefresh =
            hadStoredVersion && storedQualitySchema < backgroundArtworkQualitySchema
        let migratedVersion = storedVersion + (needsHighResolutionRefresh ? 1 : 0)
        return max(migratedVersion, minimumBackgroundCacheVersion)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        applyLoginItemSetting(enabled)
    }

    func beginAccessing(_ kind: BookmarkKind) -> ScopedAccess? {
        let path = gamesDirectory
        guard !path.isEmpty else { return nil }

        // Never fall back to probing a stored plain-text path. Apart from
        // bypassing App Sandbox, that can trigger a broad Files & Folders
        // permission prompt before the user has interacted with Sol. A stale
        // bookmark instead makes the UI ask the user to choose the folder
        // again through NSOpenPanel.
        guard let url = resolveBookmark(for: kind) else { return nil }
        let pathURL = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let bookmarkedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard bookmarkedURL.path == pathURL.path else { return nil }

        let needsStop = bookmarkedURL.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: bookmarkedURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return ScopedAccess(url: bookmarkedURL, stop: {
                if needsStop {
                    bookmarkedURL.stopAccessingSecurityScopedResource()
                }
            })
        }
        if needsStop {
            bookmarkedURL.stopAccessingSecurityScopedResource()
        }
        return nil
    }

    private func resolveBookmark(for kind: BookmarkKind) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey(for: kind)) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isStale {
            storeBookmark(for: kind, url: url)
        }
        return url
    }

    private func bookmarkKey(for _: BookmarkKind) -> String {
        Keys.gamesDirectoryBookmark
    }

    private func applyLoginItemSetting(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return
        }
    }
}
