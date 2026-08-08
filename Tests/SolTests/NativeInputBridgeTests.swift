import XCTest
@testable import Sol

@MainActor
final class NativeInputBridgeTests: XCTestCase {
    func testCommonMacKeysMapToSDLPhysicalScancodes() {
        XCTAssertEqual(SolEngineRenderView.sdlScancode(for: 0), 4) // A
        XCTAssertEqual(SolEngineRenderView.sdlScancode(for: 13), 26) // W
        XCTAssertEqual(SolEngineRenderView.sdlScancode(for: 36), 40) // Return
        XCTAssertEqual(SolEngineRenderView.sdlScancode(for: 53), 41) // Escape
        XCTAssertEqual(SolEngineRenderView.sdlScancode(for: 56), 225) // Left Shift
        XCTAssertEqual(SolEngineRenderView.sdlScancode(for: 123), 80) // Left Arrow
    }

    func testUnknownMacKeyDoesNotEmitAnInputEvent() {
        XCTAssertNil(SolEngineRenderView.sdlScancode(for: 66))
        XCTAssertNil(SolEngineRenderView.sdlScancode(for: 128))
    }

    func testRapidKeyboardChordsFinishInANeutralState() {
        var tracker = SolKeyboardInputStateTracker()
        var transitions: [SolKeyboardInputTransition] = []

        for _ in 0..<100 {
            transitions += tracker.update(keyCode: 13, scancode: 26, pressed: true) // W
            transitions += tracker.update(keyCode: 0, scancode: 4, pressed: true) // A
            transitions += tracker.update(keyCode: 13, scancode: 26, pressed: false)
            transitions += tracker.update(keyCode: 2, scancode: 7, pressed: true) // D
            transitions += tracker.update(keyCode: 0, scancode: 4, pressed: false)
            transitions += tracker.update(keyCode: 1, scancode: 22, pressed: true) // S
            transitions += tracker.update(keyCode: 2, scancode: 7, pressed: false)
            transitions += tracker.update(keyCode: 1, scancode: 22, pressed: false)
        }

        XCTAssertTrue(tracker.pressedScancodes.isEmpty)
        for scancode in [4, 7, 22, 26] {
            XCTAssertEqual(
                transitions.last(where: { $0.scancode == scancode })?.pressed,
                false
            )
        }
    }

    func testKeyboardAutorepeatDoesNotQueueDuplicatePresses() {
        var tracker = SolKeyboardInputStateTracker()

        XCTAssertEqual(
            tracker.update(keyCode: 13, scancode: 26, pressed: true),
            [SolKeyboardInputTransition(scancode: 26, pressed: true)]
        )
        XCTAssertTrue(
            tracker.update(keyCode: 13, scancode: 26, pressed: true).isEmpty
        )
        XCTAssertEqual(
            tracker.update(keyCode: 13, scancode: 26, pressed: false),
            [SolKeyboardInputTransition(scancode: 26, pressed: false)]
        )
    }
}
