import Foundation

struct SolPlayActivityEntry: Codable, Equatable, Identifiable {
    let id: String
    let timestampUnixSeconds: Int64
    let room: String
    let kind: String
    let version: UInt32
    let titleID: String

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampUnixSeconds))
    }

    var activityTitle: String {
        let normalized = room
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Game activity" }
        return normalized.capitalized
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestampUnixSeconds
        case room
        case kind
        case version
        case titleID = "titleId"
    }
}

struct SolPlayActivityFile: Decodable {
    let schemaVersion: Int
    let titleID: String
    let entries: [FileEntry]

    struct FileEntry: Decodable {
        let id: String
        let timestampUnixSeconds: Int64
        let room: String
        let kind: String
        let version: UInt32
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case titleID = "titleId"
        case entries
    }
}
