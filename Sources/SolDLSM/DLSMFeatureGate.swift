import Foundation

/// Keeps the experimental DLSM path out of normal Sol builds and launches.
///
/// DLSM remains available to local graphics work only when Sol is launched
/// with `SOL_ENABLE_DLSM=1`. Keeping the gate in the framework means a stale
/// saved preference cannot silently re-enable the renderer in a public build.
public enum DLSMFeatureGate {
    public static let environmentKey = "SOL_ENABLE_DLSM"

    public static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    public static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    public static func resolvedConfiguration(
        _ requested: DLSMConfiguration,
        capabilities: DLSMCapabilities,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DLSMConfiguration {
        guard isEnabled(environment: environment) else {
            return disabledConfiguration(preserving: requested)
        }

        return requested.resolved(for: capabilities)
    }

    public static func disabledConfiguration(
        preserving requested: DLSMConfiguration
    ) -> DLSMConfiguration {
        DLSMConfiguration(
            mode: .off,
            quality: requested.quality,
            frameGeneration: false
        )
    }
}
