import CryptoKit
import Foundation

struct SolCloudSyncContext: Sendable {
    let accountIdentifier: String
    let deviceIdentifier: String
    let engineRootURL: URL
    let profileRootURL: URL
    let localStateRootURL: URL
    let cloudRootURL: URL
    let launcherSettingsData: Data?
}

enum SolCloudReconciliationMode: Sendable {
    case automatic
    case keepThisMac
    case useICloud
}

struct SolCloudReconciliationResult: Sendable {
    enum Outcome: Sendable {
        case uploaded
        case restored
        case unchanged
        case conflict
    }

    let outcome: Outcome
    let manifest: SolCloudBackupManifest?
    let restoredLauncherSettingsData: Data?
    let recoveryURL: URL?
}

actor SolCloudBackupCoordinator {
    private struct PortableModPreferences: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let mods: [PortableModPreference]
        let enabledCheats: [String]
    }

    private struct PortableModPreference: Codable {
        let name: String
        let root: PortableModRoot
        let pathComponents: [String]
        let enabled: Bool
    }

    private enum PortableModRoot: String, Codable {
        case sol
        case sdCard
    }

    private struct EngineModMetadata: Codable {
        var mods: [EngineModMetadataItem] = []
    }

    private struct EngineModMetadataItem: Codable {
        var name: String
        var path: String
        var enabled: Bool
    }

    private struct CurrentPointer: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let snapshotID: UUID
        let createdAt: Date
    }

    private struct LocalLedger: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let snapshotID: UUID
        let localFingerprint: String
        let synchronizedAt: Date
    }

    private struct LocalPayload {
        let entry: SolCloudBackupEntry
        let sourceURL: URL?
        let data: Data?
    }

    private struct LocalScan {
        let payloads: [LocalPayload]
        let fingerprint: String
        let hasMeaningfulData: Bool
    }

    private let fileManager = FileManager.default

    func reconcile(
        context: SolCloudSyncContext,
        mode: SolCloudReconciliationMode
    ) throws -> SolCloudReconciliationResult {
        try prepareDirectories(context: context)

        let local = try scanLocalData(context: context)
        let ledger = try loadLedger(context: context)
        let cloudManifest = try loadCurrentManifest(context: context)

        switch mode {
        case .keepThisMac:
            let manifest = try upload(
                local: local,
                parentSnapshotID: cloudManifest?.id,
                context: context
            )
            return SolCloudReconciliationResult(
                outcome: .uploaded,
                manifest: manifest,
                restoredLauncherSettingsData: nil,
                recoveryURL: nil
            )

        case .useICloud:
            guard let cloudManifest else {
                throw SolCloudError.noCloudSnapshot
            }
            return try restore(manifest: cloudManifest, context: context)

        case .automatic:
            guard let cloudManifest else {
                let manifest = try upload(
                    local: local,
                    parentSnapshotID: nil,
                    context: context
                )
                return SolCloudReconciliationResult(
                    outcome: .uploaded,
                    manifest: manifest,
                    restoredLauncherSettingsData: nil,
                    recoveryURL: nil
                )
            }

            let cloudFingerprint = fingerprint(for: cloudManifest.entries)

            guard let ledger else {
                if local.fingerprint == cloudFingerprint {
                    try saveLedger(
                        manifest: cloudManifest,
                        localFingerprint: cloudFingerprint,
                        context: context
                    )
                    return SolCloudReconciliationResult(
                        outcome: .unchanged,
                        manifest: cloudManifest,
                        restoredLauncherSettingsData: nil,
                        recoveryURL: nil
                    )
                }

                if !local.hasMeaningfulData {
                    return try restore(manifest: cloudManifest, context: context)
                }

                return SolCloudReconciliationResult(
                    outcome: .conflict,
                    manifest: cloudManifest,
                    restoredLauncherSettingsData: nil,
                    recoveryURL: nil
                )
            }

            if ledger.snapshotID == cloudManifest.id {
                if ledger.localFingerprint == local.fingerprint {
                    return SolCloudReconciliationResult(
                        outcome: .unchanged,
                        manifest: cloudManifest,
                        restoredLauncherSettingsData: nil,
                        recoveryURL: nil
                    )
                }

                let manifest = try upload(
                    local: local,
                    parentSnapshotID: cloudManifest.id,
                    context: context
                )
                return SolCloudReconciliationResult(
                    outcome: .uploaded,
                    manifest: manifest,
                    restoredLauncherSettingsData: nil,
                    recoveryURL: nil
                )
            }

            if local.fingerprint == ledger.localFingerprint {
                return try restore(manifest: cloudManifest, context: context)
            }

            if local.fingerprint == cloudFingerprint {
                try saveLedger(
                    manifest: cloudManifest,
                    localFingerprint: cloudFingerprint,
                    context: context
                )
                return SolCloudReconciliationResult(
                    outcome: .unchanged,
                    manifest: cloudManifest,
                    restoredLauncherSettingsData: nil,
                    recoveryURL: nil
                )
            }

            return SolCloudReconciliationResult(
                outcome: .conflict,
                manifest: cloudManifest,
                restoredLauncherSettingsData: nil,
                recoveryURL: nil
            )
        }
    }

    private func prepareDirectories(context: SolCloudSyncContext) throws {
        try fileManager.createDirectory(
            at: accountCloudRoot(context: context),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: accountStateRoot(context: context),
            withIntermediateDirectories: true
        )
    }

    private func scanLocalData(context: SolCloudSyncContext) throws -> LocalScan {
        var payloads: [LocalPayload] = []

        try collectDirectory(
            context.engineRootURL.appendingPathComponent("bis/user/save", isDirectory: true),
            relativePrefix: "save-data",
            category: .saveData,
            into: &payloads
        )
        try collectDirectory(
            context.engineRootURL.appendingPathComponent("save-vault", isDirectory: true),
            relativePrefix: "save-vault",
            category: .saveData,
            into: &payloads
        )
        try collectDirectory(
            context.engineRootURL.appendingPathComponent("screenshots", isDirectory: true),
            relativePrefix: "screenshots",
            category: .screenshots,
            into: &payloads
        )
        try collectFile(
            context.engineRootURL.appendingPathComponent("system/Profiles.json"),
            relativePath: "game-profiles/Profiles.json",
            category: .gameProfiles,
            into: &payloads
        )
        try collectDirectory(
            context.profileRootURL,
            relativePrefix: "profile",
            category: .profile,
            into: &payloads
        )
        try collectPortableGameMetadata(context: context, into: &payloads)

        let engineConfigurationURL = context.engineRootURL.appendingPathComponent("Config.json")
        if let data = try sanitizedEngineConfiguration(at: engineConfigurationURL) {
            payloads.append(
                try payload(
                    data: data,
                    relativePath: "settings/engine.json",
                    category: .settings
                )
            )
        }
        if let data = context.launcherSettingsData {
            payloads.append(
                try payload(
                    data: data,
                    relativePath: "settings/launcher.json",
                    category: .settings
                )
            )
        }

        payloads.sort { $0.entry.relativePath < $1.entry.relativePath }
        let entries = payloads.map(\.entry)
        let meaningfulCategories: Set<SolCloudDataCategory> = [
            .saveData,
            .screenshots,
            .playActivity,
        ]
        let hasMeaningfulData = entries.contains {
            meaningfulCategories.contains($0.category) && $0.byteCount > 0
        }

        return LocalScan(
            payloads: payloads,
            fingerprint: fingerprint(for: entries),
            hasMeaningfulData: hasMeaningfulData
        )
    }

    private func collectPortableGameMetadata(
        context: SolCloudSyncContext,
        into payloads: inout [LocalPayload]
    ) throws {
        let gamesRoot = context.engineRootURL.appendingPathComponent("games", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: gamesRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let portableNames: Set<String> = [
            "metadata.json",
            "activity.json",
        ]

        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let relativePath = relativePath(of: url, below: gamesRoot) else {
                continue
            }
            let titleID = relativePath.split(separator: "/").first.map(String.init) ?? ""
            guard isTitleID(titleID) else { continue }

            if url.lastPathComponent == "mods.json" {
                if let data = try portableModPreferences(
                    from: url,
                    relativePath: relativePath,
                    context: context
                ) {
                    payloads.append(
                        try payload(
                            data: data,
                            relativePath: "title-settings/\(titleID)/mods.portable.json",
                            category: .settings
                        )
                    )
                }
                continue
            }

            guard portableNames.contains(url.lastPathComponent) else { continue }

            let category: SolCloudDataCategory =
                ["metadata.json", "activity.json"].contains(url.lastPathComponent)
                    ? .playActivity
                    : .settings
            let prefix = category == .playActivity ? "activity" : "title-settings"
            try collectFile(
                url,
                relativePath: "\(prefix)/\(relativePath)",
                category: category,
                into: &payloads
            )
        }
    }

    private func portableModPreferences(
        from metadataURL: URL,
        relativePath: String,
        context: SolCloudSyncContext
    ) throws -> Data? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count == 2,
              components[1] == "mods.json",
              isTitleID(components[0]),
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(EngineModMetadata.self, from: data) else {
            return nil
        }

        let titleID = components[0]
        let roots: [(PortableModRoot, URL)] = [
            (
                .sol,
                context.engineRootURL.appendingPathComponent(
                    "mods/contents/\(titleID)",
                    isDirectory: true
                )
            ),
            (
                .sdCard,
                context.engineRootURL.appendingPathComponent(
                    "sdcard/atmosphere/contents/\(titleID)",
                    isDirectory: true
                )
            ),
        ]

        var portable: [PortableModPreference] = []
        for item in metadata.mods {
            let itemURL = URL(fileURLWithPath: item.path).standardizedFileURL
            guard let match = roots.compactMap({ root, rootURL -> PortableModPreference? in
                guard let pathComponents = portablePathComponents(of: itemURL, below: rootURL) else {
                    return nil
                }
                return PortableModPreference(
                    name: item.name,
                    root: root,
                    pathComponents: pathComponents,
                    enabled: item.enabled
                )
            }).first else {
                // External and absolute device paths are deliberately local-only.
                continue
            }
            portable.append(match)
        }
        portable.sort {
            ($0.root.rawValue, $0.pathComponents.joined(separator: "/"), $0.name)
                < ($1.root.rawValue, $1.pathComponents.joined(separator: "/"), $1.name)
        }

        let cheatsURL = roots[0].1.appendingPathComponent("cheats/enabled.txt")
        let enabledCheats = ((try? String(contentsOf: cheatsURL, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            PortableModPreferences(
                schemaVersion: PortableModPreferences.currentSchemaVersion,
                mods: portable,
                enabledCheats: enabledCheats
            )
        )
    }

    private func collectDirectory(
        _ root: URL,
        relativePrefix: String,
        category: SolCloudDataCategory,
        into payloads: inout [LocalPayload]
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let relative = relativePath(of: url, below: root) else {
                continue
            }
            try collectFile(
                url,
                relativePath: "\(relativePrefix)/\(relative)",
                category: category,
                into: &payloads
            )
        }
    }

    private func collectFile(
        _ url: URL,
        relativePath: String,
        category: SolCloudDataCategory,
        into payloads: inout [LocalPayload]
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              isSafeRelativePath(relativePath) else { return }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let entry = SolCloudBackupEntry(
            relativePath: relativePath,
            category: category,
            contentHash: try hashFile(at: url),
            byteCount: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
        payloads.append(LocalPayload(entry: entry, sourceURL: url, data: nil))
    }

    private func payload(
        data: Data,
        relativePath: String,
        category: SolCloudDataCategory
    ) throws -> LocalPayload {
        guard isSafeRelativePath(relativePath) else {
            throw SolCloudError.invalidRelativePath
        }
        return LocalPayload(
            entry: SolCloudBackupEntry(
                relativePath: relativePath,
                category: category,
                contentHash: hash(data: data),
                byteCount: Int64(data.count),
                modifiedAt: Date()
            ),
            sourceURL: nil,
            data: data
        )
    }

    private func upload(
        local: LocalScan,
        parentSnapshotID: UUID?,
        context: SolCloudSyncContext
    ) throws -> SolCloudBackupManifest {
        for payload in local.payloads {
            let destination = blobURL(for: payload.entry.contentHash, context: context)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = payload.data {
                try writeAtomically(data, to: destination)
            } else if let sourceURL = payload.sourceURL {
                try copyAtomically(from: sourceURL, to: destination)
            }
        }

        let manifest = SolCloudBackupManifest(
            schemaVersion: SolCloudBackupManifest.currentSchemaVersion,
            id: UUID(),
            accountIdentifier: context.accountIdentifier,
            parentSnapshotID: parentSnapshotID,
            deviceIdentifier: context.deviceIdentifier,
            createdAt: Date(),
            includedCategories: Set(SolCloudDataCategory.allCases),
            entries: local.payloads.map(\.entry)
        )
        let manifestURL = snapshotURL(id: manifest.id, context: context)
        try writeJSON(manifest, to: manifestURL)
        try writeJSON(
            CurrentPointer(
                schemaVersion: CurrentPointer.currentSchemaVersion,
                snapshotID: manifest.id,
                createdAt: manifest.createdAt
            ),
            to: currentPointerURL(context: context)
        )
        try saveLedger(
            manifest: manifest,
            localFingerprint: local.fingerprint,
            context: context
        )
        return manifest
    }

    private func restore(
        manifest: SolCloudBackupManifest,
        context: SolCloudSyncContext
    ) throws -> SolCloudReconciliationResult {
        guard manifest.schemaVersion == SolCloudBackupManifest.currentSchemaVersion,
              manifest.accountIdentifier == context.accountIdentifier else {
            throw SolCloudError.incompatibleSnapshot
        }

        let recoveryURL = try createRecoveryCopy(context: context)
        let stagingRoot = accountStateRoot(context: context)
            .appendingPathComponent("Restore", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        var restoredLauncherSettingsData: Data?
        for entry in manifest.entries {
            guard isSafeRelativePath(entry.relativePath) else {
                throw SolCloudError.invalidRelativePath
            }
            let blob = blobURL(for: entry.contentHash, context: context)
            guard fileManager.fileExists(atPath: blob.path),
                  try hashFile(at: blob) == entry.contentHash else {
                throw SolCloudError.missingOrDamagedBlob
            }

            if entry.relativePath == "settings/launcher.json" {
                restoredLauncherSettingsData = try Data(contentsOf: blob)
                continue
            }
            if entry.relativePath == "settings/engine.json" {
                try mergeEngineConfiguration(from: blob, context: context)
                continue
            }
            if entry.relativePath.hasPrefix("title-settings/"),
               entry.relativePath.hasSuffix("/mods.portable.json") {
                try mergePortableModPreferences(
                    from: blob,
                    relativePath: entry.relativePath,
                    context: context
                )
                continue
            }

            guard let relativeDestination = restoreRelativeDestination(for: entry) else {
                continue
            }
            let destination = stagingRoot.appendingPathComponent(relativeDestination)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: blob, to: destination)
        }

        try applyStagedRestore(
            stagingRoot: stagingRoot,
            manifest: manifest,
            context: context
        )

        let refreshedLocal = try scanLocalData(
            context: SolCloudSyncContext(
                accountIdentifier: context.accountIdentifier,
                deviceIdentifier: context.deviceIdentifier,
                engineRootURL: context.engineRootURL,
                profileRootURL: context.profileRootURL,
                localStateRootURL: context.localStateRootURL,
                cloudRootURL: context.cloudRootURL,
                launcherSettingsData: restoredLauncherSettingsData ?? context.launcherSettingsData
            )
        )
        try saveLedger(
            manifest: manifest,
            localFingerprint: refreshedLocal.fingerprint,
            context: context
        )

        return SolCloudReconciliationResult(
            outcome: .restored,
            manifest: manifest,
            restoredLauncherSettingsData: restoredLauncherSettingsData,
            recoveryURL: recoveryURL
        )
    }

    private func createRecoveryCopy(context: SolCloudSyncContext) throws -> URL? {
        let candidates: [(URL, String)] = [
            (context.engineRootURL.appendingPathComponent("bis/user/save"), "save-data"),
            (context.engineRootURL.appendingPathComponent("system/Profiles.json"), "game-profiles/Profiles.json"),
            (context.engineRootURL.appendingPathComponent("Config.json"), "settings/Config.json"),
            (context.profileRootURL, "profile"),
        ]
        guard candidates.contains(where: { fileManager.fileExists(atPath: $0.0.path) }) else {
            return nil
        }

        let recoveryURL = accountStateRoot(context: context)
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date()), isDirectory: true)
        for (source, relativePath) in candidates {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = recoveryURL.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        }
        return recoveryURL
    }

    private func applyStagedRestore(
        stagingRoot: URL,
        manifest: SolCloudBackupManifest,
        context: SolCloudSyncContext
    ) throws {
        if manifest.includedCategories.contains(.saveData) {
            let staged = stagingRoot.appendingPathComponent("engine/bis/user/save", isDirectory: true)
            try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
            try replaceDirectory(
                at: context.engineRootURL.appendingPathComponent("bis/user/save", isDirectory: true),
                with: staged
            )
        }

        if manifest.includedCategories.contains(.profile) {
            let staged = stagingRoot.appendingPathComponent("profile", isDirectory: true)
            try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
            try replaceDirectory(at: context.profileRootURL, with: staged)
        }

        let stagedScreenshots = stagingRoot.appendingPathComponent("engine/screenshots", isDirectory: true)
        try mergeDirectory(
            from: stagedScreenshots,
            to: context.engineRootURL.appendingPathComponent("screenshots", isDirectory: true)
        )

        let stagedGameProfile = stagingRoot.appendingPathComponent("engine/system/Profiles.json")
        if fileManager.fileExists(atPath: stagedGameProfile.path) {
            try replaceFile(
                at: context.engineRootURL.appendingPathComponent("system/Profiles.json"),
                with: stagedGameProfile
            )
        }

        try mergeDirectory(
            from: stagingRoot.appendingPathComponent("engine/games", isDirectory: true),
            to: context.engineRootURL.appendingPathComponent("games", isDirectory: true)
        )
        try mergeDirectory(
            from: stagingRoot.appendingPathComponent("engine/save-vault", isDirectory: true),
            to: context.engineRootURL.appendingPathComponent("save-vault", isDirectory: true)
        )
    }

    private func restoreRelativeDestination(for entry: SolCloudBackupEntry) -> String? {
        if entry.relativePath.hasPrefix("save-data/") {
            return "engine/bis/user/save/" + entry.relativePath.dropFirst("save-data/".count)
        }
        if entry.relativePath.hasPrefix("save-vault/") {
            return "engine/save-vault/" + entry.relativePath.dropFirst("save-vault/".count)
        }
        if entry.relativePath.hasPrefix("screenshots/") {
            return "engine/screenshots/" + entry.relativePath.dropFirst("screenshots/".count)
        }
        if entry.relativePath == "game-profiles/Profiles.json" {
            return "engine/system/Profiles.json"
        }
        if entry.relativePath.hasPrefix("profile/") {
            return String(entry.relativePath)
        }
        if entry.relativePath.hasPrefix("activity/") {
            return "engine/games/" + entry.relativePath.dropFirst("activity/".count)
        }
        if entry.relativePath.hasPrefix("title-settings/") {
            return "engine/games/" + entry.relativePath.dropFirst("title-settings/".count)
        }
        return nil
    }

    private func replaceDirectory(at destination: URL, with staged: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let previous = destination.deletingLastPathComponent()
            .appendingPathComponent(".sol-cloud-previous-\(UUID().uuidString)")
        let hadPrevious = fileManager.fileExists(atPath: destination.path)

        if hadPrevious {
            try fileManager.moveItem(at: destination, to: previous)
        }
        do {
            try fileManager.moveItem(at: staged, to: destination)
            if hadPrevious {
                try? fileManager.removeItem(at: previous)
            }
        } catch {
            if hadPrevious, fileManager.fileExists(atPath: previous.path) {
                try? fileManager.moveItem(at: previous, to: destination)
            }
            throw error
        }
    }

    private func replaceFile(at destination: URL, with staged: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Data(contentsOf: staged)
        try writeAtomically(data, to: destination)
    }

    private func mergeDirectory(from source: URL, to destination: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let sourceFile = enumerator.nextObject() as? URL {
            let values = try sourceFile.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                  let relative = relativePath(of: sourceFile, below: source) else { continue }
            let destinationFile = destination.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: destinationFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationFile.path),
               try hashFile(at: destinationFile) == hashFile(at: sourceFile) {
                continue
            }
            try copyAtomically(from: sourceFile, to: destinationFile)
        }
    }

    private func mergeEngineConfiguration(
        from cloudURL: URL,
        context: SolCloudSyncContext
    ) throws {
        let targetURL = context.engineRootURL.appendingPathComponent("Config.json")
        let cloudData = try Data(contentsOf: cloudURL)
        guard let cloudValues = try JSONSerialization.jsonObject(with: cloudData) as? [String: Any] else {
            throw SolCloudError.incompatibleSnapshot
        }
        var localValues: [String: Any] = [:]
        if let localData = try? Data(contentsOf: targetURL),
           let decoded = try? JSONSerialization.jsonObject(with: localData) as? [String: Any] {
            localValues = decoded
        }
        for key in Self.portableEngineConfigurationKeys {
            if let value = cloudValues[key] {
                localValues[key] = value
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: localValues,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try writeAtomically(data, to: targetURL)
    }

    private func mergePortableModPreferences(
        from cloudURL: URL,
        relativePath: String,
        context: SolCloudSyncContext
    ) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count == 3,
              components[0] == "title-settings",
              isTitleID(components[1]),
              components[2] == "mods.portable.json" else {
            throw SolCloudError.incompatibleSnapshot
        }

        let preferences = try JSONDecoder().decode(
            PortableModPreferences.self,
            from: Data(contentsOf: cloudURL)
        )
        guard preferences.schemaVersion == PortableModPreferences.currentSchemaVersion else {
            throw SolCloudError.incompatibleSnapshot
        }

        let titleID = components[1]
        let roots: [PortableModRoot: URL] = [
            .sol: context.engineRootURL.appendingPathComponent(
                "mods/contents/\(titleID)",
                isDirectory: true
            ),
            .sdCard: context.engineRootURL.appendingPathComponent(
                "sdcard/atmosphere/contents/\(titleID)",
                isDirectory: true
            ),
        ]
        guard preferences.mods.allSatisfy({ preference in
            preference.pathComponents.allSatisfy(isSafePathComponent)
        }) else {
            throw SolCloudError.invalidRelativePath
        }

        let metadataURL = context.engineRootURL.appendingPathComponent(
            "games/\(titleID)/mods.json"
        )
        var metadata = (try? JSONDecoder().decode(
            EngineModMetadata.self,
            from: Data(contentsOf: metadataURL)
        )) ?? EngineModMetadata()
        metadata.mods.removeAll { item in
            let itemURL = URL(fileURLWithPath: item.path).standardizedFileURL
            return roots.values.contains { portablePathComponents(of: itemURL, below: $0) != nil }
        }
        metadata.mods.append(contentsOf: preferences.mods.compactMap { preference in
            guard let root = roots[preference.root] else { return nil }
            let path = preference.pathComponents.reduce(root) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            return EngineModMetadataItem(
                name: preference.name,
                path: path.standardizedFileURL.path,
                enabled: preference.enabled
            )
        })
        metadata.mods.sort {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeAtomically(try encoder.encode(metadata), to: metadataURL)

        let enabledCheatsURL = roots[.sol]!.appendingPathComponent("cheats/enabled.txt")
        let enabledCheats = Set(
            preferences.enabledCheats
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }
        )
        let enabledCheatsData = Data(
            (enabledCheats.sorted().joined(separator: "\n") + (enabledCheats.isEmpty ? "" : "\n")).utf8
        )
        try writeAtomically(enabledCheatsData, to: enabledCheatsURL)
    }

    private func sanitizedEngineConfiguration(at url: URL) throws -> Data? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let portable = object.filter { Self.portableEngineConfigurationKeys.contains($0.key) }
        return try JSONSerialization.data(
            withJSONObject: portable,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static let portableEngineConfigurationKeys: Set<String> = [
        "start_fullscreen", "docked_mode", "use_hypervisor", "enable_ptc",
        "enable_low_power_ptc", "enable_macro_hle", "gclow_latency",
        "enable_shader_cache", "enable_texture_recompression",
        "enable_color_space_passthrough", "enable_keyboard", "enable_mouse",
        "disable_input_when_out_of_focus", "ignore_applet", "skip_user_profiles",
        "enable_internet_access", "multiplayer_mode", "multiplayer_disable_p2p",
        "ldn_server", "enable_fs_integrity_checks", "match_system_time",
        "system_time_zone", "res_scale", "res_scale_custom", "max_anisotropy",
        "custom_vsync_interval", "scaling_filter_level", "audio_volume",
        "system_language", "system_region", "backend_threading", "hide_cursor",
        "dram_size", "memory_manager_mode", "vsync_mode", "aspect_ratio",
        "anti_aliasing", "scaling_filter", "audio_backend",
    ]

    private func loadCurrentManifest(context: SolCloudSyncContext) throws -> SolCloudBackupManifest? {
        let pointerURL = currentPointerURL(context: context)
        guard fileManager.fileExists(atPath: pointerURL.path) else { return nil }
        try? fileManager.startDownloadingUbiquitousItem(at: pointerURL)
        let pointer: CurrentPointer = try readJSON(CurrentPointer.self, from: pointerURL)
        guard pointer.schemaVersion == CurrentPointer.currentSchemaVersion else {
            throw SolCloudError.incompatibleSnapshot
        }
        let manifest: SolCloudBackupManifest = try readJSON(
            SolCloudBackupManifest.self,
            from: snapshotURL(id: pointer.snapshotID, context: context)
        )
        return manifest
    }

    private func loadLedger(context: SolCloudSyncContext) throws -> LocalLedger? {
        let url = ledgerURL(context: context)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let ledger: LocalLedger = try readJSON(LocalLedger.self, from: url)
        guard ledger.schemaVersion == LocalLedger.currentSchemaVersion else { return nil }
        return ledger
    }

    private func saveLedger(
        manifest: SolCloudBackupManifest,
        localFingerprint: String,
        context: SolCloudSyncContext
    ) throws {
        try writeJSON(
            LocalLedger(
                schemaVersion: LocalLedger.currentSchemaVersion,
                snapshotID: manifest.id,
                localFingerprint: localFingerprint,
                synchronizedAt: Date()
            ),
            to: ledgerURL(context: context)
        )
    }

    private func fingerprint(for entries: [SolCloudBackupEntry]) -> String {
        let canonical = entries
            .sorted { $0.relativePath < $1.relativePath }
            .map { "\($0.relativePath)|\($0.category.rawValue)|\($0.contentHash)" }
            .joined(separator: "\n")
        return hash(data: Data(canonical.utf8))
    }

    private func hash(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func relativePath(of url: URL, below root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        return isSafeRelativePath(relative) ? relative : nil
    }

    private func portablePathComponents(of url: URL, below root: URL) -> [String]? {
        let rootURL = root.standardizedFileURL
        let candidateURL = url.standardizedFileURL
        if candidateURL.path == rootURL.path { return [] }
        guard let relative = relativePath(of: candidateURL, below: rootURL) else { return nil }
        let components = relative.split(separator: "/").map(String.init)
        return components.allSatisfy(isSafePathComponent) ? components : nil
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private func isTitleID(_ value: String) -> Bool {
        value.count == 16 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/") else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try writeAtomically(try encoder.encode(value), to: url)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    private func copyAtomically(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".sol-cloud-\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: source, to: temporary)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func accountCloudRoot(context: SolCloudSyncContext) -> URL {
        context.cloudRootURL
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(context.accountIdentifier, isDirectory: true)
    }

    private func accountStateRoot(context: SolCloudSyncContext) -> URL {
        context.localStateRootURL
            .appendingPathComponent(context.accountIdentifier, isDirectory: true)
    }

    private func currentPointerURL(context: SolCloudSyncContext) -> URL {
        accountCloudRoot(context: context).appendingPathComponent("Current.json")
    }

    private func snapshotURL(id: UUID, context: SolCloudSyncContext) -> URL {
        accountCloudRoot(context: context)
            .appendingPathComponent("Snapshots", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private func blobURL(for hash: String, context: SolCloudSyncContext) -> URL {
        accountCloudRoot(context: context)
            .appendingPathComponent("Blobs", isDirectory: true)
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    private func ledgerURL(context: SolCloudSyncContext) -> URL {
        accountStateRoot(context: context).appendingPathComponent("ledger.json")
    }

    private enum SolCloudError: LocalizedError {
        case incompatibleSnapshot
        case invalidRelativePath
        case missingOrDamagedBlob
        case noCloudSnapshot

        var errorDescription: String? {
            switch self {
            case .incompatibleSnapshot:
                "This iCloud backup was created by an incompatible Sol version."
            case .invalidRelativePath:
                "The iCloud backup contains an unsafe file path."
            case .missingOrDamagedBlob:
                "Part of the iCloud backup is missing or damaged."
            case .noCloudSnapshot:
                "This Apple Account does not have a Sol Cloud snapshot yet. Choose Back Up This Mac to create one."
            }
        }
    }
}
