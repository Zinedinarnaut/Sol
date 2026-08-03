import XCTest
@testable import Sol

final class SettingsStoreTests: XCTestCase {
    func testExistingArtworkCacheIsRefreshedOnceForHighResolutionMigration() {
        XCTAssertEqual(
            SettingsStore.resolvedBackgroundCacheVersion(
                storedVersion: 4,
                hadStoredVersion: true,
                storedQualitySchema: 0
            ),
            5
        )
    }

    func testMigratedArtworkCacheDoesNotRefreshAgain() {
        XCTAssertEqual(
            SettingsStore.resolvedBackgroundCacheVersion(
                storedVersion: 5,
                hadStoredVersion: true,
                storedQualitySchema: 1
            ),
            5
        )
    }

    func testFreshInstallStartsAtCurrentMinimumWithoutExtraBump() {
        XCTAssertEqual(
            SettingsStore.resolvedBackgroundCacheVersion(
                storedVersion: 0,
                hadStoredVersion: false,
                storedQualitySchema: 0
            ),
            2
        )
    }
}
