import Foundation
import GameController
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
            #"{"protocol":1,"event":"input.mapping","inputId":"dualsense","inputName":"DualSense Wireless Controller","playerIndex":"Player1","bindings":{"buttonA":"B","buttonB":"A","buttonPlus":"Plus"},"deadzoneLeft":0.12,"motionEnabled":true,"motionSensitivity":125,"rumbleEnabled":true,"strongRumble":0.9,"hdRumble":true,"ledColor":1193046}"#
                .data(using: .utf8)
        )

        let event = try JSONDecoder().decode(
            SolEngineNativeEvent.self,
            from: data
        )

        XCTAssertEqual(event.bindings?["buttonA"], "B")
        XCTAssertEqual(event.bindings?["buttonB"], "A")
        XCTAssertEqual(event.bindings?["buttonPlus"], "Plus")
        XCTAssertEqual(event.deadzoneLeft, 0.12)
        XCTAssertEqual(event.motionEnabled, true)
        XCTAssertEqual(event.motionSensitivity, 125)
        XCTAssertEqual(event.rumbleEnabled, true)
        XCTAssertEqual(event.strongRumble, 0.9)
        XCTAssertEqual(event.hdRumble, true)
        XCTAssertEqual(event.ledColor, 0x123456)
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

    func testRapidVirtualControllerInputStaysIsolatedDuringEmulation() throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try XCTUnwrap(controller.extendedGamepad)
        let service = ControllerManagerService()
        var controllerUpdates = 0
        var navigationActions: [ControllerNavigationAction] = []
        var latestInput: ControllerInputSnapshot?

        service.onControllersChanged = { controllers in
            guard let input = controllers.last?.input else { return }
            controllerUpdates += 1
            latestInput = input
        }
        service.onNavigate = { navigationActions.append($0) }
        service.start()
        defer {
            NotificationCenter.default.post(
                name: NSNotification.Name.GCControllerDidDisconnect,
                object: controller
            )
            service.stop()
        }

        NotificationCenter.default.post(
            name: NSNotification.Name.GCControllerDidConnect,
            object: controller
        )
        drainMainRunLoop()
        XCTAssertGreaterThan(controllerUpdates, 0)

        service.setEmulationActive(true)
        let updatesAtLaunch = controllerUpdates

        for step in 0..<1_000 {
            let horizontal: Float = step.isMultiple(of: 2) ? -1 : 1
            let vertical: Float = step.isMultiple(of: 3) ? -1 : 1
            gamepad.leftThumbstick.setValueForXAxis(
                horizontal,
                yAxis: vertical
            )
            gamepad.dpad.setValueForXAxis(-horizontal, yAxis: -vertical)
            gamepad.buttonA.setValue(step.isMultiple(of: 2) ? 1 : 0)
        }
        gamepad.leftThumbstick.setValueForXAxis(0, yAxis: 0)
        gamepad.dpad.setValueForXAxis(0, yAxis: 0)
        gamepad.buttonA.setValue(0)
        drainMainRunLoop()

        XCTAssertEqual(controllerUpdates, updatesAtLaunch)
        XCTAssertTrue(navigationActions.isEmpty)

        // Re-enabling observation captures the current state as its baseline,
        // so movement held while the game closes cannot leak into the library.
        gamepad.leftThumbstick.setValueForXAxis(1, yAxis: 0)
        service.setEmulationActive(false)
        drainMainRunLoop()
        XCTAssertEqual(latestInput?.leftStickX, 1)
        XCTAssertTrue(navigationActions.isEmpty)

        gamepad.leftThumbstick.setValueForXAxis(0, yAxis: 0)
        drainMainRunLoop()
        gamepad.leftThumbstick.setValueForXAxis(-1, yAxis: 0)
        drainMainRunLoop()
        XCTAssertEqual(navigationActions, [.previous])
    }

    private func drainMainRunLoop(for duration: TimeInterval = 0.12) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
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
