import Foundation
import XCTest
@testable import Sol

final class SolPlayActivityLibraryTests: XCTestCase {
    @MainActor
    func testLoadsSafeActivityFilesAndRegistersLiveUpdates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolActivityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let validURL = root.appendingPathComponent(
            "games/0100000000000000/gui/activity.json"
        )
        try FileManager.default.createDirectory(
            at: validURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"schemaVersion":1,"titleId":"0100000000000000","entries":[{"id":"older","timestampUnixSeconds":100,"room":"race_lobby","kind":"Normal","version":1},{"id":"newer","timestampUnixSeconds":200,"room":"online_room","kind":"Normal","version":2}]}"#.utf8
        ).write(to: validURL)

        let unsafeURL = root.appendingPathComponent("games/not-a-title/gui/activity.json")
        try FileManager.default.createDirectory(
            at: unsafeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"schemaVersion":1,"titleId":"not-a-title","entries":[{"id":"unsafe","timestampUnixSeconds":300,"room":"private","kind":"Normal","version":1}]}"#.utf8
        ).write(to: unsafeURL)

        let library = SolPlayActivityLibrary()
        library.connect(to: root)
        XCTAssertEqual(library.entries.map(\.id), ["newer", "older"])
        XCTAssertEqual(library.entries.first?.titleID, "0100000000000000")
        XCTAssertEqual(library.entries.first?.activityTitle, "Online Room")

        library.register(
            SolPlayActivityEntry(
                id: "newer",
                timestampUnixSeconds: 400,
                room: "updated_room",
                kind: "Normal",
                version: 3,
                titleID: "0100000000000000"
            )
        )
        XCTAssertEqual(library.entries.filter { $0.id == "newer" }.count, 1)
        XCTAssertEqual(library.entries.first?.activityTitle, "Updated Room")
    }
}
