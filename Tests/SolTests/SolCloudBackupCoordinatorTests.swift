@testable import Sol
import Foundation
import XCTest

final class SolCloudBackupCoordinatorTests: XCTestCase, @unchecked Sendable {
    func testSnapshotIncludesPortableDataAndExcludesSensitiveMaterial() async throws {
        let roots = try TemporaryCloudRoots()
        defer { roots.remove() }

        try roots.writeEngine("save", at: "bis/user/save/0001/save.dat")
        try roots.writeEngine("capture", at: "screenshots/Game_2026-08-08_10-20-30.png")
        try roots.writeEngine("profiles", at: "system/Profiles.json")
        try roots.writeEngine("activity", at: "games/0100000000000000/gui/metadata.json")
        try roots.writeEngine("activity-events", at: "games/0100000000000000/gui/activity.json")
        try roots.writeEngine("vault-save", at: "save-vault/snapshots/example/data/save.dat")
        try roots.writeProfile("social", at: "friends-v1.json")
        try roots.writeEngine(
            #"{"start_fullscreen":true,"autoload_dirs":["/private/games"],"multiplayer_ldn_passphrase":"secret"}"#,
            at: "Config.json"
        )

        try roots.writeEngine("never", at: "system/prod.keys")
        try roots.writeEngine("never", at: "bis/system/Contents/registered/firmware.nca")
        try roots.writeEngine("never", at: "games/title/game.nsp")
        try roots.writeEngine("never", at: "games/title/cache/shader.bin")
        try roots.writeEngine("never", at: "Logs/engine.log")
        try roots.writeEngine(
            #"{"paths":["/private/content/update.nsp"],"selected":"/private/content/update.nsp"}"#,
            at: "games/0100000000000000/updates.json"
        )
        try roots.writeEngine(
            #"[{"path":"/private/content/dlc.nsp","dlc_nca_list":[]}]"#,
            at: "games/0100000000000000/dlc.json"
        )

        let modRoot = roots.engine.appendingPathComponent(
            "mods/contents/0100000000000000/Visual Pack",
            isDirectory: true
        )
        try roots.writeEngine(
            """
            {
              "mods": [
                {"name":"Visual Pack","path":"\(modRoot.path)","enabled":false},
                {"name":"External","path":"/private/external-mod","enabled":true}
              ]
            }
            """,
            at: "games/0100000000000000/mods.json"
        )
        try roots.writeEngine(
            "<60 FPS Cheat>\n",
            at: "mods/contents/0100000000000000/cheats/enabled.txt"
        )

        let coordinator = SolCloudBackupCoordinator()
        let result = try await coordinator.reconcile(
            context: roots.context(launcherSettingsData: Data("launcher".utf8)),
            mode: .automatic
        )

        guard case .uploaded = result.outcome,
              let manifest = result.manifest else {
            return XCTFail("Expected the first reconciliation to upload a snapshot.")
        }

        let paths = Set(manifest.entries.map(\.relativePath))
        XCTAssertTrue(paths.contains("save-data/0001/save.dat"))
        XCTAssertTrue(paths.contains("screenshots/Game_2026-08-08_10-20-30.png"))
        XCTAssertTrue(paths.contains("game-profiles/Profiles.json"))
        XCTAssertTrue(paths.contains("activity/0100000000000000/gui/metadata.json"))
        XCTAssertTrue(paths.contains("activity/0100000000000000/gui/activity.json"))
        XCTAssertTrue(paths.contains("save-vault/snapshots/example/data/save.dat"))
        XCTAssertTrue(paths.contains("title-settings/0100000000000000/mods.portable.json"))
        XCTAssertTrue(paths.contains("profile/friends-v1.json"))
        XCTAssertTrue(paths.contains("settings/engine.json"))
        XCTAssertTrue(paths.contains("settings/launcher.json"))
        XCTAssertFalse(paths.contains { $0.localizedCaseInsensitiveContains("prod.keys") })
        XCTAssertFalse(paths.contains { $0.localizedCaseInsensitiveContains("firmware") })
        XCTAssertFalse(paths.contains { $0.localizedCaseInsensitiveContains("shader") })
        XCTAssertFalse(paths.contains { $0.localizedCaseInsensitiveContains("game.nsp") })
        XCTAssertFalse(paths.contains { $0.localizedCaseInsensitiveContains("engine.log") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("updates.json") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("dlc.json") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("/mods.json") })

        let modEntry = try XCTUnwrap(
            manifest.entries.first {
                $0.relativePath == "title-settings/0100000000000000/mods.portable.json"
            }
        )
        let modBlob = try Data(contentsOf: roots.blobURL(for: modEntry.contentHash))
        let portableModText = String(decoding: modBlob, as: UTF8.self)
        XCTAssertFalse(portableModText.contains(roots.engine.path))
        XCTAssertFalse(portableModText.contains("/private/external-mod"))
        XCTAssertTrue(portableModText.contains("Visual Pack"))
        XCTAssertTrue(portableModText.contains("<60 FPS Cheat>"))

        let settingsEntry = try XCTUnwrap(
            manifest.entries.first { $0.relativePath == "settings/engine.json" }
        )
        let blobURL = roots.cloud
            .appendingPathComponent("Accounts/test-account/Blobs")
            .appendingPathComponent(String(settingsEntry.contentHash.prefix(2)))
            .appendingPathComponent(settingsEntry.contentHash)
        let settings = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: blobURL)) as? [String: Any]
        )
        XCTAssertEqual(settings["start_fullscreen"] as? Bool, true)
        XCTAssertNil(settings["autoload_dirs"])
        XCTAssertNil(settings["multiplayer_ldn_passphrase"])
    }

    func testFreshClientAutomaticallyRestoresLatestCloudSnapshot() async throws {
        let first = try TemporaryCloudRoots()
        defer { first.remove() }
        try first.writeEngine("cloud-save", at: "bis/user/save/0001/save.dat")
        try first.writeEngine(#"{"start_fullscreen":true}"#, at: "Config.json")

        let coordinator = SolCloudBackupCoordinator()
        _ = try await coordinator.reconcile(
            context: first.context(),
            mode: .automatic
        )

        let second = try TemporaryCloudRoots(cloudURL: first.cloud)
        defer { second.remove() }
        try second.writeEngine(#"{"start_fullscreen":false}"#, at: "Config.json")

        let restored = try await coordinator.reconcile(
            context: second.context(),
            mode: .automatic
        )

        guard case .restored = restored.outcome else {
            return XCTFail("A fresh client should restore the existing cloud snapshot.")
        }
        XCTAssertEqual(
            try String(
                contentsOf: second.engine.appendingPathComponent("bis/user/save/0001/save.dat"),
                encoding: .utf8
            ),
            "cloud-save"
        )
        let config = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: second.engine.appendingPathComponent("Config.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(config["start_fullscreen"] as? Bool, true)
    }

    func testDivergentDataRequiresChoiceAndManualRestoreKeepsRecoveryCopy() async throws {
        let first = try TemporaryCloudRoots()
        defer { first.remove() }
        try first.writeEngine("cloud-save", at: "bis/user/save/0001/save.dat")

        let coordinator = SolCloudBackupCoordinator()
        _ = try await coordinator.reconcile(
            context: first.context(),
            mode: .automatic
        )

        let second = try TemporaryCloudRoots(cloudURL: first.cloud)
        defer { second.remove() }
        try second.writeEngine("local-save", at: "bis/user/save/0001/save.dat")

        let conflict = try await coordinator.reconcile(
            context: second.context(),
            mode: .automatic
        )
        guard case .conflict = conflict.outcome else {
            return XCTFail("Divergent save data must not be overwritten automatically.")
        }

        let restored = try await coordinator.reconcile(
            context: second.context(),
            mode: .useICloud
        )
        guard case .restored = restored.outcome else {
            return XCTFail("The explicit iCloud choice should restore the cloud snapshot.")
        }
        XCTAssertEqual(
            try String(
                contentsOf: second.engine.appendingPathComponent("bis/user/save/0001/save.dat"),
                encoding: .utf8
            ),
            "cloud-save"
        )
        let recoveryURL = try XCTUnwrap(restored.recoveryURL)
        XCTAssertEqual(
            try String(
                contentsOf: recoveryURL.appendingPathComponent("save-data/0001/save.dat"),
                encoding: .utf8
            ),
            "local-save"
        )
    }

    func testPortableModPreferencesRestoreAgainstTheNewEngineRoot() async throws {
        let first = try TemporaryCloudRoots()
        defer { first.remove() }
        let titleID = "0100000000000000"
        let originalModPath = first.engine.appendingPathComponent(
            "mods/contents/\(titleID)/Visual Pack",
            isDirectory: true
        ).path
        try first.writeEngine(
            #"{"mods":[{"name":"Visual Pack","path":"\#(originalModPath)","enabled":false}]}"#,
            at: "games/\(titleID)/mods.json"
        )
        try first.writeEngine(
            "<Wide Camera Cheat>\n",
            at: "mods/contents/\(titleID)/cheats/enabled.txt"
        )

        let coordinator = SolCloudBackupCoordinator()
        _ = try await coordinator.reconcile(context: first.context(), mode: .automatic)

        let second = try TemporaryCloudRoots(cloudURL: first.cloud)
        defer { second.remove() }
        let restored = try await coordinator.reconcile(context: second.context(), mode: .automatic)
        guard case .restored = restored.outcome else {
            return XCTFail("The fresh client should restore portable mod preferences.")
        }

        let metadataData = try Data(
            contentsOf: second.engine.appendingPathComponent("games/\(titleID)/mods.json")
        )
        let metadataText = String(decoding: metadataData, as: UTF8.self)
        XCTAssertTrue(metadataText.contains(second.engine.path))
        XCTAssertFalse(metadataText.contains(first.engine.path))
        XCTAssertTrue(metadataText.contains("Visual Pack"))
        XCTAssertTrue(metadataText.contains("false"))
        XCTAssertEqual(
            try String(
                contentsOf: second.engine.appendingPathComponent(
                    "mods/contents/\(titleID)/cheats/enabled.txt"
                ),
                encoding: .utf8
            ),
            "<Wide Camera Cheat>\n"
        )
    }

    func testUseICloudDoesNotUploadWhenNoCloudSnapshotExists() async throws {
        let roots = try TemporaryCloudRoots()
        defer { roots.remove() }
        try roots.writeEngine("local-save", at: "bis/user/save/0001/save.dat")

        do {
            _ = try await SolCloudBackupCoordinator().reconcile(
                context: roots.context(),
                mode: .useICloud
            )
            XCTFail("Use iCloud should require an existing cloud snapshot.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not have a Sol Cloud snapshot"))
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: roots.cloud.appendingPathComponent(
                    "Accounts/test-account/Current.json"
                ).path
            )
        )
    }
}

private final class TemporaryCloudRoots {
    let root: URL
    let engine: URL
    let profile: URL
    let state: URL
    let cloud: URL

    init(cloudURL: URL? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolCloudTests-\(UUID().uuidString)", isDirectory: true)
        engine = root.appendingPathComponent("Engine", isDirectory: true)
        profile = root.appendingPathComponent("Profiles", isDirectory: true)
        state = root.appendingPathComponent("State", isDirectory: true)
        cloud = cloudURL ?? root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    }

    func context(launcherSettingsData: Data? = nil) -> SolCloudSyncContext {
        SolCloudSyncContext(
            accountIdentifier: "test-account",
            deviceIdentifier: root.lastPathComponent,
            engineRootURL: engine,
            profileRootURL: profile,
            localStateRootURL: state,
            cloudRootURL: cloud,
            launcherSettingsData: launcherSettingsData
        )
    }

    func writeEngine(_ value: String, at path: String) throws {
        try write(value, root: engine, path: path)
    }

    func writeProfile(_ value: String, at path: String) throws {
        try write(value, root: profile, path: path)
    }

    func blobURL(for hash: String) -> URL {
        cloud
            .appendingPathComponent("Accounts/test-account/Blobs")
            .appendingPathComponent(String(hash.prefix(2)))
            .appendingPathComponent(hash)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ value: String, root: URL, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url, options: .atomic)
    }
}
