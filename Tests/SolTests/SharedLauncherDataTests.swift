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
}
