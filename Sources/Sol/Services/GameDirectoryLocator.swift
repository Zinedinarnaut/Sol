import Foundation

final class GameDirectoryLocator {
    private static let upstreamDataDirectoryName = "Ryujinx"
    private let fileManager = FileManager.default

    func autoDetectGamesDirectory() -> String? {
        if let configPath = detectFromSolEngineConfig() {
            return configPath
        }

        if let volumePath = detectFromVolumes() {
            return volumePath
        }

        if let documentsPath = detectFromDocuments() {
            return documentsPath
        }

        return nil
    }

    private func detectFromSolEngineConfig() -> String? {
        let candidates: [URL] = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/\(Self.upstreamDataDirectoryName)/Config.json"
                ),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    ".config/\(Self.upstreamDataDirectoryName)/Config.json"
                )
        ]

        for configURL in candidates {
            guard let data = try? Data(contentsOf: configURL) else { continue }
            guard let config = try? JSONDecoder().decode(SolEngineConfig.self, from: data) else { continue }
            if let path = config.gameDirs.first(where: { isValidDirectory($0) }) {
                return path
            }
        }

        return nil
    }

    private func detectFromVolumes() -> String? {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        for volume in contents {
            let candidate = volume.appendingPathComponent("Emulation/Switch/Games", isDirectory: true)
            if isValidDirectory(candidate.path) {
                return candidate.path
            }
        }

        return nil
    }

    private func detectFromDocuments() -> String? {
        let candidate = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Emulation/Switch/Games", isDirectory: true)
        if isValidDirectory(candidate.path) {
            return candidate.path
        }
        return nil
    }

    private func isValidDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

private struct SolEngineConfig: Decodable {
    let gameDirs: [String]

    enum CodingKeys: String, CodingKey {
        case gameDirs = "game_dirs"
    }
}
