import Foundation
import XCTest
@testable import Sol

final class AmiiboCatalogServiceTests: XCTestCase {
    func testCurrentCatalogMergesRyubingGameCompatibility() throws {
        let api = Data(
            """
            {
              "amiibo": [{
                "amiiboSeries": "Kart Series",
                "character": "Sol",
                "gameSeries": "Sol Racing",
                "head": "01020304",
                "image": "https://images.example/sol.png",
                "name": "Sol Driver",
                "tail": "05060708",
                "type": "Figure"
              }]
            }
            """.utf8
        )
        let compatibility = Data(
            """
            {
              "amiibo": [{
                "head": "01020304",
                "tail": "05060708",
                "gamesSwitch": [{
                  "gameID": ["0100152000022000"]
                }]
              }]
            }
            """.utf8
        )

        let catalog = try AmiiboCatalogService.decodeCatalog(
            apiData: api,
            compatibilityData: compatibility
        )
        let item = try XCTUnwrap(catalog.first)

        XCTAssertEqual(item.scanID, "0102030405060708")
        XCTAssertTrue(item.isCompatible(with: "0100152000022000"))
        XCTAssertFalse(item.isCompatible(with: "FFFFFFFFFFFFFFFF"))
    }

    func testCatalogRejectsNonHTTPSImagesWithoutDroppingItem() throws {
        let api = Data(
            """
            {
              "amiibo": [{
                "amiiboSeries": "Series",
                "character": "Character",
                "gameSeries": "Game",
                "head": "01020304",
                "image": "http://images.example/unsafe.png",
                "name": "Example",
                "tail": "05060708",
                "type": "Figure"
              }]
            }
            """.utf8
        )

        let catalog = try AmiiboCatalogService.decodeCatalog(
            apiData: api,
            compatibilityData: nil
        )

        XCTAssertEqual(catalog.count, 1)
        XCTAssertNil(catalog[0].imageURL)
    }
}
