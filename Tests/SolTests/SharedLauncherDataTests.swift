import Foundation
import XCTest
@testable import Sol

final class SharedLauncherDataTests: XCTestCase {
    func testPendingLaunchRequiresARecentTimestamp() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(
            SharedDataStore.isPendingLaunchFresh(
                requestedAt: now.addingTimeInterval(-30),
                now: now
            )
        )
        XCTAssertFalse(
            SharedDataStore.isPendingLaunchFresh(
                requestedAt: now.addingTimeInterval(-121),
                now: now
            )
        )
        XCTAssertFalse(SharedDataStore.isPendingLaunchFresh(requestedAt: nil, now: now))
    }

    func testLaunchURLParsesIDAndDecodedStandardizedPath() throws {
        var idComponents = URLComponents()
        idComponents.scheme = "sol"
        idComponents.host = "launch"
        idComponents.queryItems = [
            URLQueryItem(name: "id", value: "/Games/Mario Kart 8 Deluxe.nsp")
        ]
        let idURL = try XCTUnwrap(idComponents.url)
        let idRequest = try XCTUnwrap(
            SharedPendingLaunchRequest(url: idURL)
        )

        XCTAssertEqual(idRequest.target, .id("/Games/Mario Kart 8 Deluxe.nsp"))

        var pathComponents = URLComponents()
        pathComponents.scheme = "sol"
        pathComponents.host = "launch"
        pathComponents.queryItems = [
            URLQueryItem(name: "path", value: "/Games/Folder/../Mario Kart 8 Deluxe.nsp")
        ]
        let pathURL = try XCTUnwrap(pathComponents.url)
        let pathRequest = try XCTUnwrap(
            SharedPendingLaunchRequest(url: pathURL)
        )

        XCTAssertEqual(
            pathRequest.target,
            .path("/Games/Mario Kart 8 Deluxe.nsp")
        )
    }

    func testDuplicateURLDeliveryCoalescesOnlySameRecentTarget() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = try XCTUnwrap(
            SharedPendingLaunchRequest(id: "game-a", requestedAt: now)
        )
        let duplicate = try XCTUnwrap(
            SharedPendingLaunchRequest(
                id: "game-a",
                requestedAt: now.addingTimeInterval(0.5)
            )
        )
        let later = try XCTUnwrap(
            SharedPendingLaunchRequest(
                id: "game-a",
                requestedAt: now.addingTimeInterval(2)
            )
        )
        let different = try XCTUnwrap(
            SharedPendingLaunchRequest(
                id: "game-b",
                requestedAt: now.addingTimeInterval(0.5)
            )
        )

        XCTAssertTrue(duplicate.duplicates(first, within: 1))
        XCTAssertFalse(later.duplicates(first, within: 1))
        XCTAssertFalse(different.duplicates(first, within: 1))
    }

    func testPendingIDWaitsForLibraryThenIsTakenExactlyOnce() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = makeSnapshot(
            games: [],
            pendingID: "game-a",
            requestedAt: now,
            solEngineValid: true,
            gamesValid: true
        )

        XCTAssertNil(
            SharedDataStore.takePendingLaunchIfReady(
                from: &snapshot,
                now: now,
                fileExists: { _ in false }
            )
        )
        XCTAssertEqual(snapshot.pendingLaunchId, "game-a")
        XCTAssertEqual(snapshot.pendingLaunchRequestedAt, now)

        snapshot.games = [makeGame(id: "game-a")]
        let request = SharedDataStore.takePendingLaunchIfReady(
            from: &snapshot,
            now: now,
            fileExists: { _ in false }
        )

        XCTAssertEqual(request?.target, .id("game-a"))
        XCTAssertNil(snapshot.pendingLaunchId)
        XCTAssertNil(snapshot.pendingLaunchPath)
        XCTAssertNil(snapshot.pendingLaunchRequestedAt)
        XCTAssertNil(
            SharedDataStore.takePendingLaunchIfReady(
                from: &snapshot,
                now: now,
                fileExists: { _ in false }
            )
        )
    }

    func testPendingIDWaitsForValidLaunchConfiguration() {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = makeSnapshot(
            games: [makeGame(id: "game-a")],
            pendingID: "game-a",
            requestedAt: now,
            solEngineValid: false,
            gamesValid: true
        )

        XCTAssertNil(
            SharedDataStore.takePendingLaunchIfReady(
                from: &snapshot,
                now: now,
                fileExists: { _ in false }
            )
        )
        XCTAssertEqual(snapshot.pendingLaunchId, "game-a")

        snapshot.solEngineValid = true
        snapshot.gamesValid = false
        XCTAssertNil(
            SharedDataStore.takePendingLaunchIfReady(
                from: &snapshot,
                now: now,
                fileExists: { _ in false }
            )
        )
        XCTAssertEqual(snapshot.pendingLaunchId, "game-a")
    }

    func testPendingPathCanBeTakenWhenFileIsDirectlyLaunchable() {
        let now = Date(timeIntervalSince1970: 10_000)
        let path = "/Outside Library/Game File.xci"
        var snapshot = makeSnapshot(
            games: [],
            pendingPath: path,
            requestedAt: now,
            solEngineValid: true,
            gamesValid: false
        )

        let request = SharedDataStore.takePendingLaunchIfReady(
            from: &snapshot,
            now: now,
            fileExists: { $0 == path }
        )

        XCTAssertEqual(request?.target, .path(path))
        XCTAssertNil(snapshot.pendingLaunchPath)
        XCTAssertNil(snapshot.pendingLaunchRequestedAt)
    }

    func testStalePendingLaunchIsClearedWithoutDelivery() {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = makeSnapshot(
            games: [makeGame(id: "game-a")],
            pendingID: "game-a",
            requestedAt: now.addingTimeInterval(-121),
            solEngineValid: true,
            gamesValid: true
        )

        XCTAssertNil(
            SharedDataStore.takePendingLaunchIfReady(
                from: &snapshot,
                now: now,
                fileExists: { _ in false }
            )
        )
        XCTAssertNil(snapshot.pendingLaunchId)
        XCTAssertNil(snapshot.pendingLaunchPath)
        XCTAssertNil(snapshot.pendingLaunchRequestedAt)
    }

    func testLegacySnapshotWithoutPendingTimestampStillDecodes() throws {
        let data = Data(
            """
            {
              "games": [],
              "pendingLaunchId": "old-request"
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(SharedLauncherSnapshot.self, from: data)

        XCTAssertEqual(snapshot.pendingLaunchId, "old-request")
        XCTAssertNil(snapshot.pendingLaunchRequestedAt)
    }

    private func makeSnapshot(
        games: [SharedGameRecord],
        pendingID: String? = nil,
        pendingPath: String? = nil,
        requestedAt: Date? = nil,
        solEngineValid: Bool?,
        gamesValid: Bool?
    ) -> SharedLauncherSnapshot {
        SharedLauncherSnapshot(
            games: games,
            lastLaunchedId: nil,
            lastLaunchedAt: nil,
            pendingLaunchId: pendingID,
            pendingLaunchPath: pendingPath,
            pendingLaunchRequestedAt: requestedAt,
            solEngineValid: solEngineValid,
            gamesValid: gamesValid
        )
    }

    private func makeGame(id: String) -> SharedGameRecord {
        SharedGameRecord(
            id: id,
            title: "Test Game",
            titleId: nil,
            hoursPlayed: 0,
            lastPlayed: nil,
            thumbnailKey: id,
            filePath: "/Games/\(id).nsp"
        )
    }
}
