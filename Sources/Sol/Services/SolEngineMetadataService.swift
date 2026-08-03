import Foundation

struct SolEngineGameMetadata: Hashable, Sendable {
    let titleId: String
    let title: String
    let hoursPlayed: Double
    let lastPlayed: Date?
}

final class SolEngineMetadataService: @unchecked Sendable {
    func loadMetadata(from dataDirectory: URL?) async -> [String: SolEngineGameMetadata] {
        guard let dataDirectory else { return [:] }
        let gamesDir = dataDirectory.appendingPathComponent("games")
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: gamesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return [:]
        }

        var result: [String: SolEngineGameMetadata] = [:]
        for url in contents {
            guard let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir == true else { continue }
            let titleId = url.lastPathComponent
            guard isValidTitleId(titleId) else { continue }

            let metadataURL = url.appendingPathComponent("gui/metadata.json")
            guard fm.fileExists(atPath: metadataURL.path) else { continue }
            guard let data = try? Data(contentsOf: metadataURL) else { continue }
            guard let metadata = try? JSONDecoder().decode(SolEngineMetadataFile.self, from: data) else { continue }

            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hours = parseTimespanToHours(metadata.timespanPlayed ?? "0:00:00")
            let lastPlayed = parseLastPlayed(metadata.lastPlayedUtc ?? metadata.lastPlayed)
            result[titleId.uppercased()] = SolEngineGameMetadata(titleId: titleId.uppercased(), title: title, hoursPlayed: hours, lastPlayed: lastPlayed)
        }

        return result
    }

    private func isValidTitleId(_ value: String) -> Bool {
        let uppercase = value.uppercased()
        let regex = try? NSRegularExpression(pattern: "^[0-9A-F]{16}$")
        let range = NSRange(location: 0, length: uppercase.utf16.count)
        return regex?.firstMatch(in: uppercase, options: [], range: range) != nil
    }

    private func parseTimespanToHours(_ timespan: String) -> Double {
        let trimmed = timespan.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }

        let parts = trimmed.split(separator: ":")
        guard parts.count >= 3 else { return 0 }

        let secondsPart = String(parts[2])
        let secondsComponents = secondsPart.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
        let seconds = Double(secondsComponents.first ?? "0") ?? 0
        let fraction = secondsComponents.count > 1 ? Double("0." + secondsComponents[1]) ?? 0 : 0

        let minutes = Double(parts[1]) ?? 0

        var days = 0.0
        var hours = 0.0
        let hourPart = String(parts[0])
        if hourPart.contains(".") {
            let dayHour = hourPart.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            days = Double(dayHour.first ?? "0") ?? 0
            hours = Double(dayHour.count > 1 ? dayHour[1] : "0") ?? 0
        } else {
            hours = Double(hourPart) ?? 0
        }

        let totalSeconds = ((days * 24 + hours) * 3600) + (minutes * 60) + seconds + fraction
        return totalSeconds / 3600
    }

    private func parseLastPlayed(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }
}

private struct SolEngineMetadataFile: Decodable {
    let title: String?
    let timespanPlayed: String?
    let lastPlayedUtc: String?
    let lastPlayed: String?

    enum CodingKeys: String, CodingKey {
        case title
        case timespanPlayed = "timespan_played"
        case lastPlayedUtc = "last_played_utc"
        case lastPlayed = "last_played"
    }
}
