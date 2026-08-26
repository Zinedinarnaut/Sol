import Foundation

enum SolSaveSnapshotReason: String, Codable, Sendable {
    case automatic
    case manual
    case beforeRestore

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .manual: "Manual"
        case .beforeRestore: "Before Restore"
        }
    }
}

struct SolSaveSnapshot: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let reason: SolSaveSnapshotReason
    let fileCount: Int
    let byteCount: Int64
    let fingerprint: String
}
