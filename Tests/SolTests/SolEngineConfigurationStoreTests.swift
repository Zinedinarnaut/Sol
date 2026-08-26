import Foundation
import XCTest
@testable import Sol

final class SolEngineConfigurationStoreTests: XCTestCase {
    @MainActor
    func testMissingConfigurationWaitsForBackendDefaultsWithoutShowingAnError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolEngineConfigMissing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = SolEngineConfigurationStore()
        store.connect(to: root)

        XCTAssertFalse(store.isLoaded)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.configURL, root.appendingPathComponent("Config.json"))

        try Data("{\"version\":70,\"enable_shader_cache\":true}".utf8)
            .write(to: root.appendingPathComponent("Config.json"))
        store.reload()

        XCTAssertTrue(store.isLoaded)
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.enableShaderCache)
    }

    @MainActor
    func testUpdatesKnownSettingsWithoutDroppingUnknownConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolEngineConfigTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let configURL = root.appendingPathComponent("Config.json")
        try Data(
            """
            {
              "version": 70,
              "enable_shader_cache": true,
              "future_upstream_setting": {"enabled": true}
            }
            """.utf8
        ).write(to: configURL)

        let store = SolEngineConfigurationStore()
        store.connect(to: root)
        store.startFullscreen = true
        store.enableShaderCache = false
        store.aspectRatio = .stretched
        store.systemLanguage = .britishEnglish
        store.backendThreading = .on
        store.memoryConfiguration = .eightGiB
        store.multiplayerMode = .onlineRooms
        store.multiplayerLanInterfaceID = "en0"
        store.multiplayerDisableP2P = true
        store.multiplayerLDNPassphrase = "Sol-123456789abc-extra"
        store.multiplayerLDNServer = "  rooms.example.test  "
        store.enableInternetAccess = true
        store.enableFileLog = false
        store.loggingEnableDebug = true
        store.loggingEnableTrace = true
        store.loggingEnableFSAccessLog = true
        store.fsGlobalAccessLogMode = 8
        store.ignoreMissingServices = true
        store.enableGDBStub = true
        store.gdbStubPort = 80
        store.debuggerSuspendOnStart = true
        store.graphicsShadersDumpPath = root.appendingPathComponent("Shader Dumps").path
        store.autoloadDirectories = [
            root.appendingPathComponent("Updates", isDirectory: true).path,
            root.appendingPathComponent("DLC", isDirectory: true).path,
            root.appendingPathComponent("Updates", isDirectory: true).path,
        ]

        let savedData = try Data(contentsOf: configURL)
        let saved = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: savedData) as? [String: Any]
        )

        XCTAssertEqual(saved["start_fullscreen"] as? Bool, true)
        XCTAssertEqual(saved["enable_shader_cache"] as? Bool, false)
        XCTAssertEqual(saved["aspect_ratio"] as? String, "Stretched")
        XCTAssertEqual(saved["system_language"] as? String, "BritishEnglish")
        XCTAssertEqual(saved["backend_threading"] as? String, "On")
        XCTAssertEqual((saved["dram_size"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((saved["multiplayer_mode"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(saved["multiplayer_lan_interface_id"] as? String, "en0")
        XCTAssertEqual(saved["multiplayer_disable_p2p"] as? Bool, true)
        XCTAssertEqual(saved["multiplayer_ldn_passphrase"] as? String, "Sol-123456789abc")
        XCTAssertEqual(saved["ldn_server"] as? String, "rooms.example.test")
        XCTAssertEqual(saved["enable_internet_access"] as? Bool, true)
        XCTAssertEqual(saved["enable_file_log"] as? Bool, false)
        XCTAssertEqual(saved["logging_enable_debug"] as? Bool, true)
        XCTAssertEqual(saved["logging_enable_trace"] as? Bool, true)
        XCTAssertEqual(saved["logging_enable_fs_access_log"] as? Bool, true)
        XCTAssertEqual((saved["fs_global_access_log_mode"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(saved["ignore_missing_services"] as? Bool, true)
        XCTAssertEqual(saved["enable_gdb_stub"] as? Bool, true)
        XCTAssertEqual((saved["gdb_stub_port"] as? NSNumber)?.intValue, 1_024)
        XCTAssertEqual(saved["debugger_suspend_on_start"] as? Bool, true)
        XCTAssertEqual(
            saved["graphics_shaders_dump_path"] as? String,
            root.appendingPathComponent("Shader Dumps").path
        )
        XCTAssertEqual(
            saved["autoload_dirs"] as? [String],
            [
                root.appendingPathComponent("DLC", isDirectory: true).path,
                root.appendingPathComponent("Updates", isDirectory: true).path,
            ]
        )
        XCTAssertEqual(store.autoloadDirectories.count, 2)
        XCTAssertNotNil(saved["future_upstream_setting"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configURL.appendingPathExtension("native-ui-backup").path
            )
        )
    }
}
