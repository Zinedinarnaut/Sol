import Foundation

final class GameScannerService: Sendable {
    private static let supportedExtensions: Set<String> = ["xci", "xcz", "nsp", "nsz", "nca", "nro", "nso", "pfs0"]

    func scanGames(in directory: URL, metadata: [String: SolEngineGameMetadata]) async throws -> [Game] {
        try await MainActor.run {
            try Self.scanGamesSynchronously(in: directory, metadata: metadata)
        }
    }

    private static func scanGamesSynchronously(in directory: URL, metadata: [String: SolEngineGameMetadata]) throws -> [Game] {
        let fileManager = FileManager.default
        // Bookmark-resolved URLs can retain security-scope coordination state.
        // The caller keeps the scope open for the scan, so enumerate through a
        // plain path URL while this short filesystem pass runs on MainActor.
        let normalizedDirectory = URL(
            fileURLWithPath: directory.path,
            isDirectory: true
        ).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalizedDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanError.cannotEnumerate(directory)
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        var byTitleId: [String: GameCandidate] = [:]
        var byPath: [String: Game] = [:]
        let metadataByTitle = unambiguousMetadataByTitle(metadata)
        var pendingDirectories = [normalizedDirectory]

        while let currentDirectory = pendingDirectories.popLast() {
            try Task.checkCancellation()

            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: currentDirectory,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles]
                )
            } catch {
                if currentDirectory == normalizedDirectory {
                    throw ScanError.cannotEnumerate(directory)
                }
                continue
            }

            for fileURL in contents {
                try Task.checkCancellation()

                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                    continue
                }

                if values.isDirectory == true {
                    if values.isSymbolicLink != true {
                        pendingDirectories.append(fileURL)
                    }
                    continue
                }

                guard values.isRegularFile == true else { continue }

                let ext = fileURL.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else { continue }

                let fileName = fileURL.deletingPathExtension().lastPathComponent
                let titleIdKey = extractTitleId(from: fileName)
                var metadataEntry = titleIdKey.flatMap { metadata[$0] }
                let sanitizedTitle = sanitizeTitle(from: fileName)
                let cleanedTitle = sanitizedTitle.isEmpty ? fileName : sanitizedTitle

                if metadataEntry == nil {
                    metadataEntry = metadataByTitle[normalize(cleanedTitle)]
                }

                let metadataTitle = metadataEntry?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = metadataTitle.flatMap { $0.isEmpty ? nil : $0 } ?? cleanedTitle
                let resolvedTitleId = (titleIdKey ?? metadataEntry?.titleId)?.uppercased()
                let id = fileURL.path
                let game = Game(
                    id: id,
                    title: title,
                    titleId: resolvedTitleId,
                    fileURL: fileURL,
                    hoursPlayed: metadataEntry?.hoursPlayed ?? 0,
                    lastPlayed: metadataEntry?.lastPlayed
                )
                let candidate = GameCandidate(
                    game: game,
                    fileSize: Int64(values.fileSize ?? 0),
                    modDate: values.contentModificationDate ?? .distantPast
                )

                if let resolvedTitleId {
                    if let existing = byTitleId[resolvedTitleId] {
                        if candidate.isPreferred(over: existing) {
                            byTitleId[resolvedTitleId] = candidate
                        }
                    } else {
                        byTitleId[resolvedTitleId] = candidate
                    }
                } else {
                    byPath[id] = game
                }
            }
        }

        var results = byTitleId.values.map(\.game)
        results.append(contentsOf: byPath.values)
        results.sort {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
        }
        return results
    }

    private static func unambiguousMetadataByTitle(_ metadata: [String: SolEngineGameMetadata]) -> [String: SolEngineGameMetadata] {
        var result: [String: SolEngineGameMetadata] = [:]
        var ambiguousTitles = Set<String>()

        for entry in metadata.values {
            let normalized = normalize(entry.title)
            guard !normalized.isEmpty, !ambiguousTitles.contains(normalized) else { continue }
            if result[normalized] == nil {
                result[normalized] = entry
            } else {
                result.removeValue(forKey: normalized)
                ambiguousTitles.insert(normalized)
            }
        }

        return result
    }

    private static func extractTitleId(from fileName: String) -> String? {
        guard let range = fileName.range(of: "[0-9a-fA-F]{16}", options: .regularExpression) else {
            return nil
        }
        return String(fileName[range]).uppercased()
    }

    private static func sanitizeTitle(from fileName: String) -> String {
        var result = fileName

        let patterns = ["\\[[^\\]]+\\]", "\\([^\\)]+\\)"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(location: 0, length: result.utf16.count)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
            }
        }

        result = result.replacingOccurrences(of: "_", with: " ")
        result = result.replacingOccurrences(of: ".", with: " ")
        result = result.replacingOccurrences(of: "-", with: " ")
        result = result.replacingOccurrences(of: "  ", with: " ")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ value: String) -> String {
        let lowered = value.lowercased()
        let tokens = lowered.split { !$0.isLetter && !$0.isNumber }
        return tokens.joined(separator: " ")
    }

    private struct GameCandidate: Sendable {
        let game: Game
        let fileSize: Int64
        let modDate: Date

        func isPreferred(over other: GameCandidate) -> Bool {
            if fileSize != other.fileSize {
                return fileSize > other.fileSize
            }
            if modDate != other.modDate {
                return modDate > other.modDate
            }
            return game.fileURL.path < other.game.fileURL.path
        }
    }

    private enum ScanError: LocalizedError {
        case cannotEnumerate(URL)

        var errorDescription: String? {
            switch self {
            case .cannotEnumerate(let directory):
                return "Could not read games directory at \(directory.path)"
            }
        }
    }
}
