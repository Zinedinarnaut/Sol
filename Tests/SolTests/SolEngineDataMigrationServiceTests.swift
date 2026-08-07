import Foundation
import XCTest
@testable import Sol

final class SolEngineDataMigrationServiceTests: XCTestCase {
    func testImportCopiesMissingItemsAndPreservesExistingSolData() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("Legacy", isDirectory: true)
        let destination = root.appendingPathComponent("Sol", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try Data("legacy config".utf8).write(
            to: source.appendingPathComponent("Config.json")
        )
        try Data("current config".utf8).write(
            to: destination.appendingPathComponent("Config.json")
        )
        let sourceSystem = source.appendingPathComponent("system", isDirectory: true)
        try fileManager.createDirectory(at: sourceSystem, withIntermediateDirectories: true)
        try Data("owned keys".utf8).write(
            to: sourceSystem.appendingPathComponent("prod.keys")
        )

        let result = try await SolEngineDataMigrationService(fileManager: fileManager)
            .importData(from: source, to: destination)

        XCTAssertEqual(result.importedItemCount, 1)
        XCTAssertEqual(result.skippedItemCount, 1)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Config.json"),
                encoding: .utf8
            ),
            "current config"
        )
        XCTAssertEqual(
            try String(
                contentsOf: destination
                    .appendingPathComponent("system")
                    .appendingPathComponent("prod.keys"),
                encoding: .utf8
            ),
            "owned keys"
        )
    }

    func testImportRejectsOverlappingDirectories() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("Sol", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await SolEngineDataMigrationService(fileManager: fileManager)
                .importData(from: root, to: destination)
            XCTFail("Expected overlapping directories to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside Sol's data directory"))
        }
    }
}
