import Foundation
import XCTest
@testable import Sol

final class SolCloudSyncServiceTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testFreshInstallWaitsForCloudBackupConsent() throws {
        let defaultsName = "SolCloudServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let service = SolCloudSyncService(defaults: defaults)

        XCTAssertFalse(service.automaticSyncEnabled)
        XCTAssertEqual(defaults.object(forKey: "sol.cloud.automatic-sync") as? Bool, false)
    }

    @MainActor
    func testAccountChangePausesAutomaticUploadUntilExplicitChoice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolCloudServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "SolCloudServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("account-one", forKey: "sol.cloud.last-account-identifier")

        let engine = root.appendingPathComponent("Engine", isDirectory: true)
        let save = engine.appendingPathComponent("bis/user/save/0001/save.dat")
        try FileManager.default.createDirectory(
            at: save.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("private-save".utf8).write(to: save)

        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        let service = SolCloudSyncService(
            defaults: defaults,
            cloudRootURL: cloud,
            localStateRootURL: root.appendingPathComponent("State", isDirectory: true),
            profileRootURL: root.appendingPathComponent("Profiles", isDirectory: true)
        )
        service.configure(
            accountIdentifier: "account-two",
            engineRootURL: engine,
            launcherSettingsData: nil
        )

        XCTAssertEqual(service.state, .accountChangeReview)
        service.synchronize(reason: .manual)
        XCTAssertEqual(service.state, .accountChangeReview)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cloud.appendingPathComponent("Accounts/account-two/Current.json").path
            )
        )

        service.keepThisMac()
        try await waitForSynchronization(service)
        guard case .synced = service.state else {
            return XCTFail("The explicit backup choice should complete the account switch.")
        }
        XCTAssertEqual(
            defaults.string(forKey: "sol.cloud.last-account-identifier"),
            "account-two"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: cloud.appendingPathComponent("Accounts/account-two/Current.json").path
            )
        )
    }

    @MainActor
    private func waitForSynchronization(_ service: SolCloudSyncService) async throws {
        for _ in 0..<300 {
            if case .syncing = service.state {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return
        }
        XCTFail("Cloud synchronization timed out")
    }
}
