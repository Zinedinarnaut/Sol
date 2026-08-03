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
}
