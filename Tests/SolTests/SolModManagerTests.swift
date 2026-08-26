import Foundation
import XCTest
@testable import Sol

final class SolModManagerTests: XCTestCase {
    @MainActor
    func testPersistsRealEngineModAndCheatSelections() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolModTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let titleID = "0100000000000000"
        let modURL = root.appendingPathComponent(
            "mods/contents/\(titleID)/Visual Pack/romfs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: modURL, withIntermediateDirectories: true)
        let cheatURL = root.appendingPathComponent(
            "mods/contents/\(titleID)/cheats/ABCDEF.txt"
        )
        try FileManager.default.createDirectory(
            at: cheatURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("[60 FPS]\n04000000 00000000 00000001\n".utf8).write(to: cheatURL)

        let manager = SolModManager()
        manager.connect(to: root)
        var inventory = try manager.load(titleID: titleID)
        let mod = try XCTUnwrap(inventory.mods.first)
        XCTAssertEqual(mod.types, ["RomFS"])
        XCTAssertTrue(mod.isEnabled)

        inventory = try manager.setModEnabled(false, item: mod, titleID: titleID)
        XCTAssertEqual(inventory.mods.first?.isEnabled, false)
        let metadata = try String(
            contentsOf: root.appendingPathComponent("games/\(titleID)/mods.json"),
            encoding: .utf8
        )
        XCTAssertTrue(metadata.contains("Visual Pack"))
        XCTAssertTrue(metadata.contains("false"))

        let cheat = try XCTUnwrap(inventory.cheats.first)
        XCTAssertEqual(cheat.engineName, "<60 FPS Cheat>")
        inventory = try manager.setCheatEnabled(true, item: cheat, titleID: titleID)
        XCTAssertEqual(inventory.cheats.first?.isEnabled, true)
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent(
                    "mods/contents/\(titleID)/cheats/enabled.txt"
                ),
                encoding: .utf8
            ),
            "<60 FPS Cheat>\n"
        )
    }

    @MainActor
    func testRejectsUnsafeTitleIdentifier() throws {
        let manager = SolModManager()
        manager.connect(to: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try manager.load(titleID: "../../private"))
    }
}
