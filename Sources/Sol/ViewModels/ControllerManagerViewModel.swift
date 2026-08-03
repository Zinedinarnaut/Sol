import Foundation
import SwiftUI
import AppKit

@MainActor
final class ControllerManagerViewModel: ObservableObject {
    @Published var controllers: [ControllerInfo] = []
    @Published var selectedControllerID: UUID?
    @Published var leftTriggerSettings = DualSenseTriggerSettings()
    @Published var rightTriggerSettings = DualSenseTriggerSettings()
    @Published var lightbarColor: Color = .white
    @Published var hapticIntensity: Double = 0.6
    @Published var hapticSharpness: Double = 0.5
    @Published var hapticDuration: Double = 0.4

    var onNavigate: ((ControllerNavigationAction) -> Void)?

    private let service: ControllerManagerService

    init(service: ControllerManagerService = ControllerManagerService()) {
        self.service = service
        service.onControllersChanged = { [weak self] controllers in
            Task { @MainActor in
                self?.updateControllers(controllers)
            }
        }
        service.onNavigate = { [weak self] action in
            Task { @MainActor in
                self?.onNavigate?(action)
            }
        }
        service.start()
    }

    deinit {
        service.stop()
    }

    var selectedController: ControllerInfo? {
        guard let selectedControllerID else { return nil }
        return controllers.first(where: { $0.id == selectedControllerID })
    }

    func selectController(_ id: UUID) {
        selectedControllerID = id
        syncLightbarColor()
    }

    func setLightbarColor() {
        guard let id = selectedControllerID else { return }
        let rgb = lightbarColor.rgbComponents
        _ = service.setLightbarColor(controllerID: id, rgb: rgb)
    }

    func applyLeftTrigger() {
        guard let id = selectedControllerID else { return }
        _ = service.applyTriggerSettings(controllerID: id, side: .left, settings: leftTriggerSettings)
    }

    func applyRightTrigger() {
        guard let id = selectedControllerID else { return }
        _ = service.applyTriggerSettings(controllerID: id, side: .right, settings: rightTriggerSettings)
    }

    func playHaptics() {
        guard let id = selectedControllerID else { return }
        service.playHaptics(controllerID: id, intensity: Float(hapticIntensity), sharpness: Float(hapticSharpness), duration: hapticDuration)
    }

    func setPollingEnabled(_ enabled: Bool) {
        service.setPollingEnabled(enabled)
    }

    func setNavigationEnabled(_ enabled: Bool) {
        service.setNavigationEnabled(enabled)
    }

    func setEmulationActive(_ active: Bool) {
        service.setEmulationActive(active)
    }

    private func updateControllers(_ newControllers: [ControllerInfo]) {
        controllers = newControllers
        if selectedControllerID == nil, let first = newControllers.first {
            selectedControllerID = first.id
            syncLightbarColor()
        } else if let selectedControllerID, !newControllers.contains(where: { $0.id == selectedControllerID }) {
            self.selectedControllerID = newControllers.first?.id
            syncLightbarColor()
        }
    }

    private func syncLightbarColor() {
        guard let id = selectedControllerID else { return }
        if let rgb = service.currentLightColor(controllerID: id) {
            lightbarColor = Color(red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2))
        }
    }
}

private extension Color {
    var rgbComponents: (Float, Float, Float) {
        let nsColor = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.white
        return (Float(nsColor.redComponent), Float(nsColor.greenComponent), Float(nsColor.blueComponent))
    }
}
