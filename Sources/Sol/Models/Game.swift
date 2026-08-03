import Foundation

struct Game: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let titleId: String?
    let fileURL: URL
    let hoursPlayed: Double
    let lastPlayed: Date?

    var formattedPlaytime: String {
        let totalSeconds = max(Int((hoursPlayed * 3_600).rounded()), 0)
        switch totalSeconds {
        case 0:
            return "Not played"
        case 1..<60:
            return "\(totalSeconds) sec"
        case 60..<3_600:
            return "\(totalSeconds / 60) min"
        default:
            let hours = totalSeconds / 3_600
            let minutes = (totalSeconds % 3_600) / 60
            return minutes == 0
                ? "\(hours) hr"
                : "\(hours) hr \(minutes) min"
        }
    }

    var formattedHoursPlayed: String {
        if hoursPlayed <= 0.01 {
            return "0.0 hrs"
        }
        return String(format: "%.1f hrs", hoursPlayed)
    }

    var formattedLastPlayed: String? {
        guard let lastPlayed else { return nil }
        if abs(Date().timeIntervalSince(lastPlayed)) < 60 {
            return "just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastPlayed, relativeTo: Date())
    }
}
