import Foundation

enum SolModSource: String, Codable, Sendable {
    case sol
    case sdCard

    var title: String {
        switch self {
        case .sol: "Sol Mods"
        case .sdCard: "SD Card"
        }
    }
}

struct SolModItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let source: SolModSource
    let types: [String]
    var isEnabled: Bool
}

struct SolCheatItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let engineName: String
    let fileName: String
    let source: SolModSource
    var isEnabled: Bool
}

struct SolModInventory: Equatable, Sendable {
    var mods: [SolModItem] = []
    var cheats: [SolCheatItem] = []
}
