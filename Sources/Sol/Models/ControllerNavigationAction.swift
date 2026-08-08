import Foundation

enum ControllerNavigationAction: Equatable {
    case previous
    case next
    case launch
    case openSettings
}

enum ControllerLauncherNavigationPolicy {
    static func isEnabled(
        navigationEnabled: Bool,
        isEmulationActive: Bool
    ) -> Bool {
        navigationEnabled && !isEmulationActive
    }

    static func buttonEdgeAction(
        previous: ControllerInputSnapshot,
        current: ControllerInputSnapshot
    ) -> ControllerNavigationAction? {
        if current.buttonA && !previous.buttonA {
            return .launch
        }

        if (current.buttonMenu && !previous.buttonMenu)
            || (current.buttonOptions && !previous.buttonOptions) {
            return .openSettings
        }

        return nil
    }
}

enum ControllerInputObservationPolicy {
    static func isEnabled(
        pollingEnabled: Bool,
        isEmulationActive: Bool
    ) -> Bool {
        pollingEnabled && !isEmulationActive
    }
}
