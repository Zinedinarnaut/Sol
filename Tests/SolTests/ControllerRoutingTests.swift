import XCTest
@testable import Sol

final class ControllerRoutingTests: XCTestCase {
    func testAssignedControllerWinsOverKeyboardForPlayer() {
        let devices = [
            device(id: "keyboard", name: "All keyboards", kind: .keyboard),
            device(
                id: "dualsense",
                name: "DualSense Wireless Controller",
                kind: .controller,
                assignedPlayers: [.player1]
            ),
        ]

        XCTAssertEqual(
            SolEngineInputSelection.preferredDeviceID(
                in: devices,
                for: .player1,
                matching: "DualSense Wireless Controller",
                currentID: "keyboard",
                preserveCurrent: false
            ),
            "dualsense"
        )
    }

    func testConnectedControllerNameWinsWhenPlayerHasNoAssignment() {
        let devices = [
            device(id: "other", name: "Other Controller", kind: .controller),
            device(id: "keyboard", name: "All keyboards", kind: .keyboard),
            device(
                id: "dualsense",
                name: "DualSense Wireless Controller",
                kind: .controller
            ),
        ]

        XCTAssertEqual(
            SolEngineInputSelection.preferredDeviceID(
                in: devices,
                for: .player2,
                matching: "dualsense wireless controller",
                currentID: nil,
                preserveCurrent: false
            ),
            "dualsense"
        )
    }

    func testManualKeyboardChoiceIsPreserved() {
        let devices = [
            device(
                id: "dualsense",
                name: "DualSense Wireless Controller",
                kind: .controller,
                assignedPlayers: [.player1]
            ),
            device(id: "keyboard", name: "All keyboards", kind: .keyboard),
        ]

        XCTAssertEqual(
            SolEngineInputSelection.preferredDeviceID(
                in: devices,
                for: .player1,
                matching: "DualSense Wireless Controller",
                currentID: "keyboard",
                preserveCurrent: true
            ),
            "keyboard"
        )
    }

    func testInputEventDecodesAssignedPlayers() throws {
        let data = try XCTUnwrap(
            #"{"protocol":1,"event":"input.device","inputId":"dualsense","inputName":"DualSense Wireless Controller","inputKind":"controller","assignedPlayers":["Player1","Player2"]}"#
                .data(using: .utf8)
        )

        let event = try JSONDecoder().decode(
            SolEngineNativeEvent.self,
            from: data
        )

        XCTAssertEqual(event.assignedPlayers, ["Player1", "Player2"])
    }

    func testControllerMappingEventDecodesBindings() throws {
        let data = try XCTUnwrap(
            #"{"protocol":1,"event":"input.mapping","inputId":"dualsense","inputName":"DualSense Wireless Controller","playerIndex":"Player1","bindings":{"buttonA":"B","buttonB":"A","buttonPlus":"Plus"}}"#
                .data(using: .utf8)
        )

        let event = try JSONDecoder().decode(
            SolEngineNativeEvent.self,
            from: data
        )

        XCTAssertEqual(event.bindings?["buttonA"], "B")
        XCTAssertEqual(event.bindings?["buttonB"], "A")
        XCTAssertEqual(event.bindings?["buttonPlus"], "Plus")
    }

    func testDualSenseButtonCaptureUsesPhysicalSDLButtons() {
        var previous = ControllerInputSnapshot()
        var current = previous
        current.buttonA = true

        XCTAssertEqual(
            current.newlyPressedPhysicalButton(comparedTo: previous),
            .a
        )
        XCTAssertEqual(SolEnginePhysicalButton.a.title(isDualSense: true), "Cross")

        previous = current
        current.buttonA = false
        current.buttonMenu = true
        XCTAssertEqual(
            current.newlyPressedPhysicalButton(comparedTo: previous),
            .plus
        )
        XCTAssertEqual(SolEnginePhysicalButton.plus.title(isDualSense: true), "Options")
    }

    func testCircleIsNeverAStopShortcut() {
        var current = ControllerInputSnapshot()
        current.buttonB = true

        XCTAssertNil(
            ControllerLauncherNavigationPolicy.buttonEdgeAction(
                previous: ControllerInputSnapshot(),
                current: current
            )
        )
    }

    func testLauncherShortcutsAreDisabledDuringEmulation() {
        XCTAssertFalse(
            ControllerLauncherNavigationPolicy.isEnabled(
                navigationEnabled: true,
                isEmulationActive: true
            )
        )
        XCTAssertTrue(
            ControllerLauncherNavigationPolicy.isEnabled(
                navigationEnabled: true,
                isEmulationActive: false
            )
        )
    }

    func testNativeControllerObservationStopsForAnEmulationSession() {
        XCTAssertTrue(
            ControllerInputObservationPolicy.isEnabled(
                pollingEnabled: true,
                isEmulationActive: false
            )
        )
        XCTAssertFalse(
            ControllerInputObservationPolicy.isEnabled(
                pollingEnabled: false,
                isEmulationActive: false
            )
        )
        XCTAssertFalse(
            ControllerInputObservationPolicy.isEnabled(
                pollingEnabled: true,
                isEmulationActive: true
            )
        )
    }

    private func device(
        id: String,
        name: String,
        kind: SolEngineInputDevice.Kind,
        assignedPlayers: [SolEnginePlayerIndex] = []
    ) -> SolEngineInputDevice {
        SolEngineInputDevice(
            id: id,
            name: name,
            kind: kind,
            usesEastConfirmButton: false,
            isConnected: true,
            assignedPlayers: assignedPlayers
        )
    }
}
