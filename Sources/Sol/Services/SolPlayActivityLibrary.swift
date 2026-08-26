import Foundation

@MainActor
final class SolPlayActivityLibrary: ObservableObject {
    @Published private(set) var entries: [SolPlayActivityEntry] = []

    private let fileManager: FileManager
    private var engineRootURL: URL?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func connect(to engineRootURL: URL?) {
        self.engineRootURL = engineRootURL
        reload()
    }

    func reload() {
        guard let engineRootURL else {
            entries = []
            return
        }

        let gamesRoot = engineRootURL.appendingPathComponent("games", isDirectory: true)
        let titleDirectories = (try? fileManager.contentsOfDirectory(
            at: gamesRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var loaded: [SolPlayActivityEntry] = []
        for titleDirectory in titleDirectories {
            guard isSafeTitleID(titleDirectory.lastPathComponent),
                  let values = try? titleDirectory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                continue
            }
            let activityURL = titleDirectory.appendingPathComponent("gui/activity.json")
            guard let data = try? Data(contentsOf: activityURL),
                  let file = try? JSONDecoder().decode(SolPlayActivityFile.self, from: data),
                  isSafeTitleID(file.titleID) else {
                continue
            }
            loaded.append(contentsOf: file.entries.map {
                SolPlayActivityEntry(
                    id: $0.id,
                    timestampUnixSeconds: $0.timestampUnixSeconds,
                    room: $0.room,
                    kind: $0.kind,
                    version: $0.version,
                    titleID: file.titleID.uppercased()
                )
            })
        }

        entries = Array(
            loaded
                .sorted { $0.timestampUnixSeconds > $1.timestampUnixSeconds }
                .prefix(500)
        )
    }

    func register(_ entry: SolPlayActivityEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > 500 {
            entries.removeLast(entries.count - 500)
        }
    }

    private func isSafeTitleID(_ value: String) -> Bool {
        value.count == 16 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }
}
