import Foundation
import XCTest
@testable import Sol

final class SolEngineMetadataServiceTests: XCTestCase, @unchecked Sendable {
    func testLoadsSolEngineMetadataAndParsesMultiDayPlaytime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolMetadataTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let titleID = "010012101468C000"
        let metadataDirectory = root
            .appendingPathComponent("games", isDirectory: true)
            .appendingPathComponent(titleID, isDirectory: true)
            .appendingPathComponent("gui", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)

        let metadataJSON = """
        {
          "title": "Metroid Prime Remastered",
          "timespan_played": "1.02:30:00.5",
          "last_played_utc": "2026-07-26T05:15:30.000Z"
        }
        """
        try Data(metadataJSON.utf8).write(to: metadataDirectory.appendingPathComponent("metadata.json"))

        let result = await SolEngineMetadataService().loadMetadata(from: root)
        let metadata = try XCTUnwrap(result[titleID])

        XCTAssertEqual(metadata.title, "Metroid Prime Remastered")
        XCTAssertEqual(metadata.hoursPlayed, 26.5001388889, accuracy: 0.0000001)
        XCTAssertEqual(metadata.lastPlayed, ISO8601DateFormatter().date(from: "2026-07-26T05:15:30Z"))
    }

    func testFormatsShortPlaytimeWithoutRoundingItBackToZeroHours() {
        let fileURL = URL(fileURLWithPath: "/tmp/test-game.nsp")

        XCTAssertEqual(
            Game(
                id: "seconds",
                title: "Seconds",
                titleId: nil,
                fileURL: fileURL,
                hoursPlayed: 32.0 / 3_600,
                lastPlayed: nil
            ).formattedPlaytime,
            "32 sec"
        )
        XCTAssertEqual(
            Game(
                id: "minutes",
                title: "Minutes",
                titleId: nil,
                fileURL: fileURL,
                hoursPlayed: 17.0 / 60,
                lastPlayed: nil
            ).formattedPlaytime,
            "17 min"
        )
        XCTAssertEqual(
            Game(
                id: "hours",
                title: "Hours",
                titleId: nil,
                fileURL: fileURL,
                hoursPlayed: 2.5,
                lastPlayed: nil
            ).formattedPlaytime,
            "2 hr 30 min"
        )
    }

    func testFreshPlaytimeUsesStableJustNowLabel() {
        let game = Game(
            id: "recent",
            title: "Recent",
            titleId: nil,
            fileURL: URL(fileURLWithPath: "/tmp/recent-game.nsp"),
            hoursPlayed: 1,
            lastPlayed: Date().addingTimeInterval(1)
        )

        XCTAssertEqual(game.formattedLastPlayed, "just now")
    }
}
