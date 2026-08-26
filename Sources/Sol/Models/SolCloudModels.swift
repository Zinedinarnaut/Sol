import Foundation

enum SolCloudDataCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case saveData
    case gameProfiles
    case profile
    case screenshots
    case playActivity
    case settings

    var title: String {
        switch self {
        case .saveData: "Save Data"
        case .gameProfiles: "Game Users"
        case .profile: "Sol Profile"
        case .screenshots: "Screenshots"
        case .playActivity: "Play Activity"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .saveData: "externaldrive.badge.icloud"
        case .gameProfiles: "person.2.crop.square.stack"
        case .profile: "person.crop.circle"
        case .screenshots: "photo.on.rectangle.angled"
        case .playActivity: "chart.bar.xaxis"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct SolCloudBackupEntry: Codable, Hashable, Sendable {
    let relativePath: String
    let category: SolCloudDataCategory
    let contentHash: String
    let byteCount: Int64
    let modifiedAt: Date
}

struct SolCloudBackupManifest: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let accountIdentifier: String
    let parentSnapshotID: UUID?
    let deviceIdentifier: String
    let createdAt: Date
    let includedCategories: Set<SolCloudDataCategory>
    let entries: [SolCloudBackupEntry]

    var totalByteCount: Int64 {
        entries.reduce(0) { $0 + $1.byteCount }
    }

    func entryCount(for category: SolCloudDataCategory) -> Int {
        entries.lazy.filter { $0.category == category }.count
    }
}

struct SolCloudBackupSummary: Equatable, Sendable {
    let snapshotID: UUID
    let createdAt: Date
    let deviceIdentifier: String
    let totalByteCount: Int64
    let counts: [SolCloudDataCategory: Int]

    init(manifest: SolCloudBackupManifest) {
        snapshotID = manifest.id
        createdAt = manifest.createdAt
        deviceIdentifier = manifest.deviceIdentifier
        totalByteCount = manifest.totalByteCount
        counts = Dictionary(
            uniqueKeysWithValues: SolCloudDataCategory.allCases.map {
                ($0, manifest.entryCount(for: $0))
            }
        )
    }
}

enum SolCloudSyncState: Equatable, Sendable {
    case waitingForAppleAccount
    case waitingForICloud
    case requiresSignedBuild
    case ready
    case accountChangeReview
    case deferredForGame
    case syncing(String)
    case synced(Date)
    case conflict(cloudDate: Date)
    case failed(String)

    var title: String {
        switch self {
        case .waitingForAppleAccount: "Connect Apple Account"
        case .waitingForICloud: "Sign in to iCloud"
        case .requiresSignedBuild: "Signed build required"
        case .ready: "Ready to Sync"
        case .accountChangeReview: "Review Before Switching Account"
        case .deferredForGame: "Sync after gameplay"
        case .syncing(let detail): detail
        case .synced: "Up to Date"
        case .conflict: "Choose Which Copy to Keep"
        case .failed: "Sync Needs Attention"
        }
    }

    var systemImage: String {
        switch self {
        case .waitingForAppleAccount: "person.crop.circle.badge.plus"
        case .waitingForICloud: "icloud.slash"
        case .requiresSignedBuild: "signature"
        case .ready: "icloud"
        case .accountChangeReview: "person.crop.circle.badge.exclamationmark"
        case .deferredForGame: "gamecontroller"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .synced: "checkmark.icloud.fill"
        case .conflict: "exclamationmark.icloud"
        case .failed: "exclamationmark.triangle"
        }
    }
}

enum SolCloudSyncReason: String, Sendable {
    case appLaunch
    case appBecameActive
    case accountChanged
    case gameplayEnded
    case screenshotCaptured
    case profileChanged
    case playActivityChanged
    case saveSnapshotChanged
    case settingsChanged
    case manual
}
