import XCTest
@testable import Sol

final class SolEngineLaunchActivityTests: XCTestCase {
    func testProgressUsesRealCountsAndKeepsRecentCompletedStages() {
        var activity = SolEngineLaunchActivity()

        activity.update(stage: "loading-content", message: "Loading game content")
        activity.update(
            stage: "shader-cache",
            message: "Compiling shaders",
            current: 25,
            total: 100
        )

        XCTAssertEqual(activity.progressFraction, 0.25)
        XCTAssertEqual(activity.progressDetail, "25 of 100")
        XCTAssertEqual(
            activity.completedMessages,
            ["Preparing the native Metal surface", "Loading game content"]
        )
        XCTAssertTrue(activity.isVisible)
    }

    func testOverlayOnlyHidesAfterFirstFrame() {
        var activity = SolEngineLaunchActivity()
        activity.update(stage: "renderer", message: "Waiting for the first Metal frame")

        XCTAssertTrue(activity.isVisible)
        activity.markFirstFramePresented()
        XCTAssertFalse(activity.isVisible)
        XCTAssertEqual(activity.message, "First Metal frame presented")
    }
}
