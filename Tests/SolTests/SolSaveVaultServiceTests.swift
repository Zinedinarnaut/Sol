import Foundation
import XCTest
@testable import Sol

final class SolSaveVaultServiceTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testAutomaticSnapshotsSkipUnchangedDataAndRestoreWithSafetyCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolSaveVaultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let saveURL = root.appendingPathComponent("bis/user/save/0001/save.dat")
        try FileManager.default.createDirectory(
            at: saveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("version-one".utf8).write(to: saveURL)

        let vault = SolSaveVaultService()
        vault.connect(to: root)
        vault.createAutomaticSnapshot()
        try await waitUntilIdle(vault)
        XCTAssertEqual(vault.snapshots.filter { $0.reason == .automatic }.count, 1)
        let original = try XCTUnwrap(vault.snapshots.first)

        vault.createAutomaticSnapshot()
        try await waitUntilIdle(vault)
        XCTAssertEqual(vault.snapshots.filter { $0.reason == .automatic }.count, 1)

        try Data("version-two-is-different".utf8).write(to: saveURL, options: .atomic)
        vault.createAutomaticSnapshot()
        try await waitUntilIdle(vault)
        XCTAssertEqual(vault.snapshots.filter { $0.reason == .automatic }.count, 2)

        vault.restore(original)
        try await waitUntilIdle(vault)
        XCTAssertEqual(try String(contentsOf: saveURL, encoding: .utf8), "version-one")
        XCTAssertTrue(vault.snapshots.contains { $0.reason == .beforeRestore })
        XCTAssertNil(vault.lastError)
    }

    @MainActor
    private func waitUntilIdle(_ vault: SolSaveVaultService) async throws {
        for _ in 0..<300 {
            if !vault.isWorking {
                await Task.yield()
                if !vault.isWorking { return }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Save Vault operation timed out")
    }
}
