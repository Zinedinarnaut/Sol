import UserNotifications
import XCTest
@testable import Sol

final class NotificationServiceTests: XCTestCase {
    func testStandardNotificationUsesActiveInterruptionLevel() {
        let content = NotificationService.makeContent(
            title: "Launching Sol",
            body: "Game",
            priority: .standard
        )

        XCTAssertEqual(content.title, "Launching Sol")
        XCTAssertEqual(content.body, "Game")
        XCTAssertEqual(content.interruptionLevel, .active)
    }

    func testUrgentNotificationUsesTimeSensitiveInterruptionLevel() {
        let content = NotificationService.makeContent(
            title: "Sol Engine Stopped",
            body: "Exit status 1",
            priority: .timeSensitive
        )

        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
    }
}
