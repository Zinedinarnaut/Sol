import Foundation
import QuartzCore
import GameController
import CoreHaptics

final class ControllerManagerService: @unchecked Sendable {
    private struct ManagedController {
        let id: UUID
        let controller: GCController
        var snapshot: ControllerInputSnapshot
    }

    private var controllersByObjectID: [ObjectIdentifier: ManagedController] = [:]
    private var objectIDByUUID: [UUID: ObjectIdentifier] = [:]
    private var hapticEngines: [UUID: CHHapticEngine] = [:]
    private var refreshTimer: Timer?
    private var inputPollTimer: Timer?
    private var lastNavTimeById: [UUID: TimeInterval] = [:]
    private var isPollingEnabled = true
    private var isNavigationEnabled = true
    private var isEmulationActive = false

    var onControllersChanged: (([ControllerInfo]) -> Void)?
    var onNavigate: ((ControllerNavigationAction) -> Void)?

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: NSNotification.Name.GCControllerDidConnect,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: NSNotification.Name.GCControllerDidDisconnect,
            object: nil
        )

        for controller in GCController.controllers() {
            register(controller)
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.isInputObservationEnabled else { return }
            self.publish()
        }

        inputPollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollInputs()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        inputPollTimer?.invalidate()
        inputPollTimer = nil
        controllersByObjectID.values.forEach { removeInputHandler(from: $0.controller) }
        NotificationCenter.default.removeObserver(self)
        GCController.stopWirelessControllerDiscovery()
    }

    func setPollingEnabled(_ enabled: Bool) {
        guard isPollingEnabled != enabled else { return }
        isPollingEnabled = enabled
        reconfigureInputObservation()
    }

    func setNavigationEnabled(_ enabled: Bool) {
        isNavigationEnabled = enabled
    }

    func setEmulationActive(_ active: Bool) {
        guard isEmulationActive != active else { return }
        isEmulationActive = active
        reconfigureInputObservation()
    }

    func setLightbarColor(controllerID: UUID, rgb: (Float, Float, Float)) -> Bool {
        guard let controller = controller(for: controllerID), let light = controller.light else { return false }
        light.color = GCColor(red: rgb.0, green: rgb.1, blue: rgb.2)
        publish()
        return true
    }

    func currentLightColor(controllerID: UUID) -> (Float, Float, Float)? {
        guard let controller = controller(for: controllerID), let light = controller.light else { return nil }
        return (light.color.red, light.color.green, light.color.blue)
    }

    func applyTriggerSettings(controllerID: UUID, side: TriggerSide, settings: DualSenseTriggerSettings) -> Bool {
        guard let controller = controller(for: controllerID), let dualSense = controller.extendedGamepad as? GCDualSenseGamepad else { return false }
        let trigger = side == .left ? dualSense.leftTrigger : dualSense.rightTrigger

        switch settings.mode {
        case .off:
            trigger.setModeOff()
        case .feedback:
            let strengths = positionalResistiveStrengths(start: settings.startPosition, end: nil, strength: settings.strength)
            trigger.setModeFeedback(resistiveStrengths: strengths)
        case .weapon:
            let strengths = positionalResistiveStrengths(start: settings.startPosition, end: settings.endPosition, strength: settings.strength)
            trigger.setModeFeedback(resistiveStrengths: strengths)
        case .vibration:
            let amplitudes = positionalAmplitudes(start: settings.startPosition, amplitude: settings.amplitude)
            trigger.setModeVibration(amplitudes: amplitudes, frequency: settings.frequency)
        case .slopeFeedback:
            if #available(macOS 12.3, *) {
                trigger.setModeSlopeFeedback(startPosition: settings.startPosition, endPosition: settings.endPosition, startStrength: settings.startStrength, endStrength: settings.endStrength)
            } else {
                trigger.setModeOff()
            }
        }

        return true
    }

    func playHaptics(controllerID: UUID, intensity: Float, sharpness: Float, duration: TimeInterval) {
        guard let controller = controller(for: controllerID), let haptics = controller.haptics else { return }

        do {
            let engine: CHHapticEngine
            if let cached = hapticEngines[controllerID] {
                engine = cached
            } else {
                guard let created = haptics.createEngine(withLocality: .default) else { return }
                engine = created
                hapticEngines[controllerID] = created
            }

            try engine.start()

            let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
            let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensityParam, sharpnessParam], relativeTime: 0, duration: duration)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            return
        }
    }

    private func controller(for id: UUID) -> GCController? {
        guard let objectID = objectIDByUUID[id], let entry = controllersByObjectID[objectID] else { return nil }
        return entry.controller
    }

    @objc private func controllerDidConnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        register(controller)
    }

    @objc private func controllerDidDisconnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        unregister(controller)
    }

    private func register(_ controller: GCController) {
        let objectID = ObjectIdentifier(controller)
        guard controllersByObjectID[objectID] == nil else { return }

        controller.handlerQueue = DispatchQueue.main

        let snapshot = snapshotForController(controller)
        let entry = ManagedController(id: UUID(), controller: controller, snapshot: snapshot)
        controllersByObjectID[objectID] = entry
        objectIDByUUID[entry.id] = objectID

        if isInputObservationEnabled {
            installInputHandler(on: controller)
        }

        publish()
    }

    private func unregister(_ controller: GCController) {
        removeInputHandler(from: controller)
        let objectID = ObjectIdentifier(controller)
        if let entry = controllersByObjectID.removeValue(forKey: objectID) {
            objectIDByUUID.removeValue(forKey: entry.id)
            hapticEngines.removeValue(forKey: entry.id)
        }
        publish()
    }

    private func updateSnapshot(for controller: GCController) {
        // GameController may already have queued callbacks when a game begins.
        // Ignore those late callbacks so rapid analog input cannot compete with
        // Sol Engine's SDL event pump on AppKit's main loop.
        guard isInputObservationEnabled else { return }
        let objectID = ObjectIdentifier(controller)
        guard var entry = controllersByObjectID[objectID] else { return }
        let previous = entry.snapshot
        let updated = snapshotForController(controller)
        guard updated != previous else { return }
        entry.snapshot = updated
        controllersByObjectID[objectID] = entry
        handleNavigation(id: entry.id, previous: previous, current: updated)
        publish()
    }

    private func publish() {
        let infos = controllersByObjectID.values.map { entry in
            info(for: entry)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onControllersChanged?(infos)
    }

    private func pollInputs() {
        guard isInputObservationEnabled else { return }
        let controllers = controllersByObjectID.values.map { $0.controller }
        for controller in controllers {
            updateSnapshot(for: controller)
        }
    }

    private var isInputObservationEnabled: Bool {
        ControllerInputObservationPolicy.isEnabled(
            pollingEnabled: isPollingEnabled,
            isEmulationActive: isEmulationActive
        )
    }

    private func reconfigureInputObservation() {
        let enabled = isInputObservationEnabled

        for objectID in Array(controllersByObjectID.keys) {
            guard var entry = controllersByObjectID[objectID] else { continue }
            removeInputHandler(from: entry.controller)

            guard enabled else { continue }

            // Establish a fresh baseline before callbacks resume. A button or
            // stick held while the game was closing must not turn into a
            // launcher shortcut when the library becomes active again.
            entry.snapshot = snapshotForController(entry.controller)
            controllersByObjectID[objectID] = entry
            installInputHandler(on: entry.controller)
        }

        if enabled {
            publish()
        }
    }

    private func installInputHandler(on controller: GCController) {
        if let gamepad = controller.extendedGamepad {
            gamepad.valueChangedHandler = { [weak self, weak controller] _, _ in
                guard let controller else { return }
                self?.updateSnapshot(for: controller)
            }
        } else if let micro = controller.microGamepad {
            micro.valueChangedHandler = { [weak self, weak controller] _, _ in
                guard let controller else { return }
                self?.updateSnapshot(for: controller)
            }
        }
    }

    private func removeInputHandler(from controller: GCController) {
        controller.extendedGamepad?.valueChangedHandler = nil
        controller.microGamepad?.valueChangedHandler = nil
    }

    private func handleNavigation(id: UUID, previous: ControllerInputSnapshot, current: ControllerInputSnapshot) {
        guard ControllerLauncherNavigationPolicy.isEnabled(
            navigationEnabled: isNavigationEnabled,
            isEmulationActive: isEmulationActive
        ) else { return }

        let now = CACurrentMediaTime()
        let lastNav = lastNavTimeById[id] ?? 0
        let canNavigate = now - lastNav > 0.16

        if let action = ControllerLauncherNavigationPolicy.buttonEdgeAction(
            previous: previous,
            current: current
        ) {
            onNavigate?(action)
        }

        guard canNavigate else { return }

        let right = (current.dpadX > 0.4 && previous.dpadX <= 0.4) || (current.leftStickX > 0.55 && previous.leftStickX <= 0.55)
        let left = (current.dpadX < -0.4 && previous.dpadX >= -0.4) || (current.leftStickX < -0.55 && previous.leftStickX >= -0.55)

        if right {
            lastNavTimeById[id] = now
            onNavigate?(.next)
        } else if left {
            lastNavTimeById[id] = now
            onNavigate?(.previous)
        }
    }

    private func info(for entry: ManagedController) -> ControllerInfo {
        let controller = entry.controller
        let vendorName = controller.vendorName
        let productCategory = controller.productCategory
        let name = vendorName ?? productCategory
        let batteryLevel = controller.battery?.batteryLevel
        let batteryState = controller.battery.map { mapBatteryState($0.batteryState) }
        let supportsHaptics = controller.haptics != nil
        let supportsLight = controller.light != nil
        let supportsDualSense = controller.extendedGamepad is GCDualSenseGamepad

        return ControllerInfo(
            id: entry.id,
            name: name,
            vendorName: vendorName,
            productCategory: productCategory,
            isAttachedToDevice: controller.isAttachedToDevice,
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            supportsHaptics: supportsHaptics,
            supportsLight: supportsLight,
            supportsDualSense: supportsDualSense,
            input: entry.snapshot
        )
    }

    private func mapBatteryState(_ state: GCDeviceBattery.State) -> String {
        switch state {
        case .charging:
            return "Charging"
        case .discharging:
            return "Discharging"
        case .full:
            return "Full"
        case .unknown:
            return "Unknown"
        @unknown default:
            return "Unknown"
        }
    }

    private func snapshotForController(_ controller: GCController) -> ControllerInputSnapshot {
        var snapshot = ControllerInputSnapshot()

        if let gamepad = controller.extendedGamepad {
            snapshot.leftStickX = gamepad.leftThumbstick.xAxis.value
            snapshot.leftStickY = gamepad.leftThumbstick.yAxis.value
            snapshot.rightStickX = gamepad.rightThumbstick.xAxis.value
            snapshot.rightStickY = gamepad.rightThumbstick.yAxis.value
            snapshot.dpadX = gamepad.dpad.xAxis.value
            snapshot.dpadY = gamepad.dpad.yAxis.value

            snapshot.leftTrigger = gamepad.leftTrigger.value
            snapshot.rightTrigger = gamepad.rightTrigger.value
            snapshot.leftShoulder = gamepad.leftShoulder.isPressed
            snapshot.rightShoulder = gamepad.rightShoulder.isPressed

            snapshot.buttonA = gamepad.buttonA.isPressed
            snapshot.buttonB = gamepad.buttonB.isPressed
            snapshot.buttonX = gamepad.buttonX.isPressed
            snapshot.buttonY = gamepad.buttonY.isPressed
            snapshot.buttonMenu = gamepad.buttonMenu.isPressed
            snapshot.buttonOptions = gamepad.buttonOptions?.isPressed ?? false
            snapshot.buttonHome = gamepad.buttonHome?.isPressed ?? false
            snapshot.leftThumbstickButton = gamepad.leftThumbstickButton?.isPressed ?? false
            snapshot.rightThumbstickButton = gamepad.rightThumbstickButton?.isPressed ?? false

            if let dualSense = gamepad as? GCDualSenseGamepad {
                snapshot.touchpadButton = dualSense.touchpadButton.isPressed
                snapshot.touchpadPrimaryX = dualSense.touchpadPrimary.xAxis.value
                snapshot.touchpadPrimaryY = dualSense.touchpadPrimary.yAxis.value
                snapshot.touchpadSecondaryX = dualSense.touchpadSecondary.xAxis.value
                snapshot.touchpadSecondaryY = dualSense.touchpadSecondary.yAxis.value
            }
        } else if let micro = controller.microGamepad {
            snapshot.dpadX = micro.dpad.xAxis.value
            snapshot.dpadY = micro.dpad.yAxis.value
            snapshot.buttonA = micro.buttonA.isPressed
            snapshot.buttonX = micro.buttonX.isPressed
            snapshot.buttonMenu = micro.buttonMenu.isPressed
        }

        return snapshot
    }

    private func positionalResistiveStrengths(start: Float, end: Float?, strength: Float) -> GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths {
        var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
        let values = positionalValues(start: start, end: end, high: strength)
        strengths.values = tuple(values)
        return strengths
    }

    private func positionalAmplitudes(start: Float, amplitude: Float) -> GCDualSenseAdaptiveTrigger.PositionalAmplitudes {
        var amplitudes = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
        let values = positionalValues(start: start, end: nil, high: amplitude)
        amplitudes.values = tuple(values)
        return amplitudes
    }

    private func positionalValues(start: Float, end: Float?, high: Float) -> [Float] {
        let clampedStart = max(0, min(1, start))
        let clampedEnd = end.map { max(0, min(1, $0)) }
        return (0..<10).map { index in
            let position = Float(index) / 9.0
            if let clampedEnd {
                return (position >= clampedStart && position <= clampedEnd) ? high : 0
            }
            return position >= clampedStart ? high : 0
        }
    }

    private func tuple(_ values: [Float]) -> (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float) {
        let padded = values.count == 10 ? values : Array(values.prefix(10)) + Array(repeating: 0, count: max(0, 10 - values.count))
        return (padded[0], padded[1], padded[2], padded[3], padded[4], padded[5], padded[6], padded[7], padded[8], padded[9])
    }
}
