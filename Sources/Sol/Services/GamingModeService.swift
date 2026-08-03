import Foundation

@MainActor
final class GamingModeService {
    private var fullscreenActivity: NSObjectProtocol?
    private var launchActivity: NSObjectProtocol?

    func setFullscreenActive(_ active: Bool) {
        if active {
            if fullscreenActivity == nil {
                fullscreenActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                    reason: "Sol Fullscreen Gaming Mode"
                )
            }
        } else if let activity = fullscreenActivity {
            ProcessInfo.processInfo.endActivity(activity)
            fullscreenActivity = nil
        }
    }

    func setLaunchActive(_ active: Bool) {
        if active {
            if launchActivity == nil {
                launchActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                    reason: "Sol Game Session"
                )
            }
        } else if let activity = launchActivity {
            ProcessInfo.processInfo.endActivity(activity)
            launchActivity = nil
        }
    }

}
