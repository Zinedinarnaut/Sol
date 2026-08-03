import Foundation
import XCTest
@testable import Sol

final class GameScannerServiceTests: XCTestCase, @unchecked Sendable {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testDuplicateNormalizedMetadataTitlesDoNotCrashOrGuess() async throws {
        let gameURL = temporaryDirectory.appendingPathComponent("Same.Game.nsp")
        try Data([0x01]).write(to: gameURL)
        let metadata = [
            "0100000000000001": SolEngineGameMetadata(
                titleId: "0100000000000001",
                title: "Same Game",
                hoursPlayed: 10,
                lastPlayed: nil
            ),
            "0100000000000002": SolEngineGameMetadata(
                titleId: "0100000000000002",
                title: "Same-Game",
                hoursPlayed: 20,
                lastPlayed: nil
            )
        ]

        let games = try await GameScannerService().scanGames(in: temporaryDirectory, metadata: metadata)

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].title, "Same Game")
        XCTAssertNil(games[0].titleId)
        XCTAssertEqual(games[0].hoursPlayed, 0)
    }

    func testUniqueNormalizedTitleMatchesMetadata() async throws {
        let gameURL = temporaryDirectory.appendingPathComponent("Metroid_Prime_Remastered.nsp")
        try Data([0x01]).write(to: gameURL)
        let lastPlayed = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = [
            "010012101468C000": SolEngineGameMetadata(
                titleId: "010012101468C000",
                title: "Metroid Prime Remastered",
                hoursPlayed: 12.5,
                lastPlayed: lastPlayed
            )
        ]

        let games = try await GameScannerService().scanGames(in: temporaryDirectory, metadata: metadata)

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].titleId, "010012101468C000")
        XCTAssertEqual(games[0].hoursPlayed, 12.5)
        XCTAssertEqual(games[0].lastPlayed, lastPlayed)
    }

    func testDuplicateTitleIDPrefersLargerFileBeforeModificationDate() async throws {
        let titleID = "010012101468C000"
        let baseURL = temporaryDirectory.appendingPathComponent("Base [\(titleID)].nsp")
        let updateURL = temporaryDirectory.appendingPathComponent("Update [\(titleID)].nsp")
        try Data(repeating: 0x01, count: 4_096).write(to: baseURL)
        try Data(repeating: 0x02, count: 32).write(to: updateURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: baseURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: updateURL.path
        )

        let games = try await GameScannerService().scanGames(in: temporaryDirectory, metadata: [:])

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].fileURL.lastPathComponent, baseURL.lastPathComponent)
    }

    func testMissingDirectoryProducesAnError() async {
        let missingURL = temporaryDirectory.appendingPathComponent("missing", isDirectory: true)

        do {
            _ = try await GameScannerService().scanGames(in: missingURL, metadata: [:])
            XCTFail("Expected scanning a missing directory to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(missingURL.path))
        }
    }
}
