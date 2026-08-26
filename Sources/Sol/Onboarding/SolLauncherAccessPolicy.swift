import Foundation

enum SolLauncherAccessPolicy {
    static func allowsLauncherInteraction(
        setupCompleted: Bool,
        splashVisible: Bool
    ) -> Bool {
        setupCompleted && !splashVisible
    }

    static func allowsControllerNavigation(
        setupCompleted: Bool,
        splashVisible: Bool,
        launchIsolationActive: Bool
    ) -> Bool {
        allowsLauncherInteraction(
            setupCompleted: setupCompleted,
            splashVisible: splashVisible
        ) && !launchIsolationActive
    }
}
