import Foundation

@MainActor
final class SolModManager {
    var onChanged: (() -> Void)?
    private var engineRootURL: URL?

    func connect(to engineRootURL: URL?) {
        self.engineRootURL = engineRootURL
    }

    func load(titleID: String) throws -> SolModInventory {
        let context = try context(for: titleID)
        return try Self.load(context: context)
    }

    func setModEnabled(
        _ enabled: Bool,
        item: SolModItem,
        titleID: String
    ) throws -> SolModInventory {
        let context = try context(for: titleID)
        var metadata = try Self.loadMetadata(at: context.metadataURL)
        if let index = metadata.mods.firstIndex(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
                .localizedCaseInsensitiveCompare(
                    URL(fileURLWithPath: item.path).standardizedFileURL.path
                ) == .orderedSame
        }) {
            metadata.mods[index].name = item.name
            metadata.mods[index].enabled = enabled
        } else {
            metadata.mods.append(
                MetadataItem(name: item.name, path: item.path, enabled: enabled)
            )
        }
        try Self.saveMetadata(metadata, at: context.metadataURL)
        onChanged?()
        return try Self.load(context: context)
    }

    func setCheatEnabled(
        _ enabled: Bool,
        item: SolCheatItem,
        titleID: String
    ) throws -> SolModInventory {
        let context = try context(for: titleID)
        let fileManager = FileManager.default
        let enabledURL = context.solContentURL
            .appendingPathComponent("cheats/enabled.txt")
        var names = Set(
            ((try? String(contentsOf: enabledURL, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        if enabled {
            names.insert(item.engineName)
        } else {
            names.remove(item.engineName)
        }
        try fileManager.createDirectory(
            at: enabledURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let output = names.sorted().joined(separator: "\n") + (names.isEmpty ? "" : "\n")
        try Data(output.utf8).write(to: enabledURL, options: .atomic)
        onChanged?()
        return try Self.load(context: context)
    }

    private func context(for titleID: String) throws -> Context {
        guard let engineRootURL else { throw ManagerError.engineUnavailable }
        let normalized = titleID.lowercased()
        guard normalized.count == 16,
              normalized.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw ManagerError.invalidTitleID
        }
        return Context(engineRootURL: engineRootURL, titleID: normalized)
    }

    nonisolated private static func load(context: Context) throws -> SolModInventory {
        let metadata = try loadMetadata(at: context.metadataURL)
        let enabledByPath = Dictionary(
            uniqueKeysWithValues: metadata.mods.map {
                (URL(fileURLWithPath: $0.path).standardizedFileURL.path.lowercased(), $0.enabled)
            }
        )
        var mods: [SolModItem] = []
        var cheats: [SolCheatItem] = []
        for (root, source) in [
            (context.solContentURL, SolModSource.sol),
            (context.sdContentURL, SolModSource.sdCard),
        ] {
            mods.append(contentsOf: scanMods(
                at: root,
                source: source,
                enabledByPath: enabledByPath
            ))
            cheats.append(contentsOf: scanCheats(at: root, source: source))
        }

        let enabledCheatsURL = context.solContentURL
            .appendingPathComponent("cheats/enabled.txt")
        let enabledCheats = Set(
            ((try? String(contentsOf: enabledCheatsURL, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        for index in cheats.indices {
            cheats[index].isEnabled = enabledCheats.contains(cheats[index].engineName)
        }

        return SolModInventory(
            mods: mods.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            cheats: cheats.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        )
    }

    nonisolated private static func scanMods(
        at rootURL: URL,
        source: SolModSource,
        enabledByPath: [String: Bool]
    ) -> [SolModItem] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        var directories = [rootURL]
        if let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ), values.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isDirectory == true {
                    directories.append(url)
                }
            }
        }

        return directories.compactMap { directory in
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let names = Set(children.map { $0.lastPathComponent.lowercased() })
            var types: [String] = []
            if names.contains("romfs") || names.contains("romfs.bin") { types.append("RomFS") }
            if names.contains("exefs") || names.contains("exefs.nsp") { types.append("ExeFS") }
            guard !types.isEmpty else { return nil }
            let path = directory.standardizedFileURL.path
            let name = directory == rootURL ? "Base content override" : directory.lastPathComponent
            return SolModItem(
                id: path,
                name: name,
                path: path,
                source: source,
                types: types,
                isEnabled: enabledByPath[path.lowercased()] ?? true
            )
        }
    }

    nonisolated private static func scanCheats(
        at rootURL: URL,
        source: SolModSource
    ) -> [SolCheatItem] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [SolCheatItem] = []

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "txt",
                  url.lastPathComponent.localizedCaseInsensitiveCompare("enabled.txt") != .orderedSame,
                  url.pathComponents.contains(where: {
                    $0.localizedCaseInsensitiveCompare("cheats") == .orderedSame
                  }),
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            result.append(contentsOf: parseCheats(contents, fileURL: url, source: source))
        }
        return result
    }

    nonisolated private static func parseCheats(
        _ contents: String,
        fileURL: URL,
        source: SolModSource
    ) -> [SolCheatItem] {
        var result: [SolCheatItem] = []
        var name = "default"
        var hasInstructions = false

        func appendCurrent() {
            guard hasInstructions else { return }
            let engineName = "<\(name) Cheat>"
            result.append(
                SolCheatItem(
                    id: "\(fileURL.path)#\(engineName)",
                    name: name,
                    engineName: engineName,
                    fileName: fileURL.lastPathComponent,
                    source: source,
                    isEnabled: false
                )
            )
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]"), line.count >= 3 {
                appendCurrent()
                name = String(line.dropFirst().dropLast())
                hasInstructions = false
            } else if !line.isEmpty {
                hasInstructions = true
            }
        }
        appendCurrent()
        return result
    }

    nonisolated private static func loadMetadata(at url: URL) throws -> Metadata {
        guard FileManager.default.fileExists(atPath: url.path) else { return Metadata() }
        do {
            return try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url))
        } catch {
            throw ManagerError.invalidMetadata
        }
    }

    nonisolated private static func saveMetadata(_ metadata: Metadata, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    private struct Context: Sendable {
        let engineRootURL: URL
        let titleID: String

        var solContentURL: URL {
            engineRootURL.appendingPathComponent("mods/contents/\(titleID)", isDirectory: true)
        }
        var sdContentURL: URL {
            engineRootURL.appendingPathComponent(
                "sdcard/atmosphere/contents/\(titleID)",
                isDirectory: true
            )
        }
        var metadataURL: URL {
            engineRootURL.appendingPathComponent("games/\(titleID)/mods.json")
        }
    }

    private struct Metadata: Codable {
        var mods: [MetadataItem] = []
    }

    private struct MetadataItem: Codable {
        var name: String
        var path: String
        var enabled: Bool
    }

    private enum ManagerError: LocalizedError {
        case engineUnavailable
        case invalidTitleID
        case invalidMetadata

        var errorDescription: String? {
            switch self {
            case .engineUnavailable: "Sol Engine data is unavailable."
            case .invalidTitleID: "This game does not have a valid title ID."
            case .invalidMetadata: "Sol would not overwrite the existing mods.json because it is malformed."
            }
        }
    }
}
