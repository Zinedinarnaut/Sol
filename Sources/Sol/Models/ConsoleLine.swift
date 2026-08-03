import Foundation

enum ConsoleStream: String, Sendable {
    case stdout
    case stderr
    case system
}

struct ConsoleLine: Identifiable, Hashable, Sendable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let stream: ConsoleStream
}
