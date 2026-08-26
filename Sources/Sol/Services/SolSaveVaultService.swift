import AppKit
import CryptoKit
import Foundation

@MainActor
final class SolSaveVaultService: ObservableObject {
    @Published private(set) var snapshots: [SolSaveSnapshot] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    var onChanged: (() -> Void)?

    private var engineRootURL: URL?

    func connect(to engineRootURL: URL?) {
        self.engineRootURL = engineRootURL
        reload()
    }

    func reload() {
        guard let engineRootURL else {
            snapshots = []
            return
        }
        let vaultURL = Self.vaultURL(for: engineRootURL)
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                Self.loadSnapshots(from: vaultURL)
            }.value
            guard self?.engineRootURL == engineRootURL else { return }
            self?.snapshots = loaded
        }
    }

    func createSnapshot() {
        createSnapshot(reason: .manual, skipIfUnchanged: false)
    }

    func createAutomaticSnapshot() {
        createSnapshot(reason: .automatic, skipIfUnchanged: true)
    }

    func restore(_ snapshot: SolSaveSnapshot) {
        guard let engineRootURL, !isWorking else { return }
        isWorking = true
        lastError = nil
        Task { [weak self] in
            do {
                let safetySnapshot = try await Task.detached(priority: .userInitiated) {
                    try Self.restoreSnapshot(snapshot, engineRootURL: engineRootURL)
                }.value
                guard let self, self.engineRootURL == engineRootURL else { return }
                self.isWorking = false
                self.snapshots = Self.loadSnapshots(from: Self.vaultURL(for: engineRootURL))
                if safetySnapshot != nil {
                    self.onChanged?()
                }
            } catch {
                guard let self else { return }
                self.isWorking = false
                self.lastError = error.localizedDescription
            }
        }
    }

    func revealVault() {
        guard let engineRootURL else { return }
        let url = Self.vaultURL(for: engineRootURL)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func clearError() {
        lastError = nil
    }

    private func createSnapshot(
        reason: SolSaveSnapshotReason,
        skipIfUnchanged: Bool
    ) {
        guard let engineRootURL, !isWorking else { return }
        isWorking = true
        lastError = nil
        Task { [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try Self.createSnapshot(
                        engineRootURL: engineRootURL,
                        reason: reason,
                        skipIfUnchanged: skipIfUnchanged
                    )
                }.value
                guard let self, self.engineRootURL == engineRootURL else { return }
                self.isWorking = false
                self.snapshots = Self.loadSnapshots(from: Self.vaultURL(for: engineRootURL))
                if snapshot != nil {
                    self.onChanged?()
                }
            } catch {
                guard let self else { return }
                self.isWorking = false
                self.lastError = error.localizedDescription
            }
        }
    }

    nonisolated private static func createSnapshot(
        engineRootURL: URL,
        reason: SolSaveSnapshotReason,
        skipIfUnchanged: Bool
    ) throws -> SolSaveSnapshot? {
        let sourceURL = engineRootURL.appendingPathComponent("bis/user/save", isDirectory: true)
        let vaultURL = vaultURL(for: engineRootURL)
        let existing = loadSnapshots(from: vaultURL)
        let inventory = try inventory(at: sourceURL)

        if skipIfUnchanged, existing.first?.fingerprint == inventory.fingerprint {
            return nil
        }

        let snapshot = SolSaveSnapshot(
            schemaVersion: SolSaveSnapshot.currentSchemaVersion,
            id: UUID(),
            createdAt: Date(),
            reason: reason,
            fileCount: inventory.fileCount,
            byteCount: inventory.byteCount,
            fingerprint: inventory.fingerprint
        )
        let snapshotsURL = vaultURL.appendingPathComponent("snapshots", isDirectory: true)
        let temporaryURL = snapshotsURL.appendingPathComponent(".creating-\(snapshot.id.uuidString)")
        let destinationURL = snapshotsURL.appendingPathComponent(snapshot.id.uuidString, isDirectory: true)
        let dataURL = temporaryURL.appendingPathComponent("data", isDirectory: true)
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)
        do {
            try copyTree(from: sourceURL, to: dataURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(
                to: temporaryURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            if reason == .automatic {
                pruneAutomaticSnapshots(in: vaultURL, keeping: 8)
            }
            return snapshot
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    nonisolated private static func restoreSnapshot(
        _ snapshot: SolSaveSnapshot,
        engineRootURL: URL
    ) throws -> SolSaveSnapshot? {
        let fileManager = FileManager.default
        let snapshotDataURL = vaultURL(for: engineRootURL)
            .appendingPathComponent("snapshots/\(snapshot.id.uuidString)/data", isDirectory: true)
        guard fileManager.fileExists(atPath: snapshotDataURL.path) else {
            throw VaultError.snapshotMissing
        }

        let safetySnapshot = try createSnapshot(
            engineRootURL: engineRootURL,
            reason: .beforeRestore,
            skipIfUnchanged: false
        )
        let liveURL = engineRootURL.appendingPathComponent("bis/user/save", isDirectory: true)
        let parentURL = liveURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(".sol-save-restore-\(UUID().uuidString)")
        let rollbackURL = parentURL.appendingPathComponent(".sol-save-rollback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try copyTree(from: snapshotDataURL, to: stagingURL)

        let hadLiveData = fileManager.fileExists(atPath: liveURL.path)
        do {
            if hadLiveData {
                try fileManager.moveItem(at: liveURL, to: rollbackURL)
            }
            try fileManager.moveItem(at: stagingURL, to: liveURL)
            if hadLiveData {
                try? fileManager.removeItem(at: rollbackURL)
            }
            return safetySnapshot
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            if hadLiveData,
               !fileManager.fileExists(atPath: liveURL.path),
               fileManager.fileExists(atPath: rollbackURL.path) {
                try? fileManager.moveItem(at: rollbackURL, to: liveURL)
            }
            throw error
        }
    }

    nonisolated private static func loadSnapshots(from vaultURL: URL) -> [SolSaveSnapshot] {
        let fileManager = FileManager.default
        let snapshotsURL = vaultURL.appendingPathComponent("snapshots", isDirectory: true)
        let directories = (try? fileManager.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let values = try? directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let data = try? Data(
                    contentsOf: directory.appendingPathComponent("manifest.json")
                  ),
                  let manifest = try? decoder.decode(SolSaveSnapshot.self, from: data),
                  manifest.schemaVersion == SolSaveSnapshot.currentSchemaVersion else {
                return nil
            }
            return manifest
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated private static func inventory(at rootURL: URL) throws -> Inventory {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return Inventory(fileCount: 0, byteCount: 0, fingerprint: "empty")
        }
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return Inventory(fileCount: 0, byteCount: 0, fingerprint: "empty")
        }

        var signatures: [String] = []
        var fileCount = 0
        var byteCount: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            signatures.append("\(relativePath(url, below: rootURL))|\(size)|\(modified)")
            fileCount += 1
            byteCount += size
        }
        let data = Data(signatures.sorted().joined(separator: "\n").utf8)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Inventory(fileCount: fileCount, byteCount: byteCount, fingerprint: fingerprint)
    }

    nonisolated private static func copyTree(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: sourceURL.path),
              let enumerator = fileManager.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
              ) else { return }

        while let source = enumerator.nextObject() as? URL {
            let values = try source.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            let destination = destinationURL.appendingPathComponent(
                relativePath(source, below: sourceURL)
            )
            if values.isDirectory == true {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }

    nonisolated private static func pruneAutomaticSnapshots(in vaultURL: URL, keeping count: Int) {
        let automatic = loadSnapshots(from: vaultURL).filter { $0.reason == .automatic }
        guard automatic.count > count else { return }
        for snapshot in automatic.dropFirst(count) {
            let url = vaultURL.appendingPathComponent(
                "snapshots/\(snapshot.id.uuidString)",
                isDirectory: true
            )
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func relativePath(_ url: URL, below rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return String(path.dropFirst(min(root.count + 1, path.count)))
    }

    nonisolated private static func vaultURL(for engineRootURL: URL) -> URL {
        engineRootURL.appendingPathComponent("save-vault", isDirectory: true)
    }

    private struct Inventory {
        let fileCount: Int
        let byteCount: Int64
        let fingerprint: String
    }

    private enum VaultError: LocalizedError {
        case snapshotMissing

        var errorDescription: String? {
            "This save snapshot is incomplete or no longer available."
        }
    }
}
