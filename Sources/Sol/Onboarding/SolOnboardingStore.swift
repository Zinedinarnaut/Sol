import Combine
import Foundation

enum SolOnboardingIdentityPolicy {
    static func initialDisplayName(_ storedDisplayName: String) -> String {
        storedDisplayName == "RyuPlayer" ? "Sol Player" : storedDisplayName
    }
}

@MainActor
final class SolOnboardingStore: ObservableObject {
    enum Step: String, CaseIterable, Identifiable {
        case welcome
        case account
        case iCloud
        case essentials
        case library
        case performance
        case ready

        var id: String { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .account: return "Profile"
            case .iCloud: return "iCloud"
            case .essentials: return "System Files"
            case .library: return "Game Library"
            case .performance: return "Emulation"
            case .ready: return "Ready"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: return "A private, native setup"
            case .account: return "Identity and Apple account"
            case .iCloud: return "Backups across Macs"
            case .essentials: return "Keys and firmware"
            case .library: return "Choose your local games"
            case .performance: return "Apple Silicon defaults"
            case .ready: return "Review your setup"
            }
        }

        var systemImage: String {
            switch self {
            case .welcome: return "sparkles"
            case .account: return "person.crop.circle"
            case .iCloud: return "icloud"
            case .essentials: return "internaldrive"
            case .library: return "rectangle.stack"
            case .performance: return "cpu"
            case .ready: return "checkmark.seal"
            }
        }
    }

    static let schemaVersion = 1
    private static let completedVersionKey = "sol.onboarding.completed-version"

    @Published private(set) var currentStep: Step = .welcome
    @Published private(set) var furthestVisitedIndex = 0
    @Published private(set) var isCompleted: Bool

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        launchOptions: SolLaunchOptions = .current()
    ) {
        self.defaults = defaults
        if launchOptions.resetOnboarding {
            defaults.removeObject(forKey: Self.completedVersionKey)
        }
        let persistedVersion = defaults.integer(forKey: Self.completedVersionKey)
        isCompleted = persistedVersion >= Self.schemaVersion && !launchOptions.showOnboarding
    }

    var progress: Double {
        let index = Step.allCases.firstIndex(of: currentStep) ?? 0
        return Double(index + 1) / Double(Step.allCases.count)
    }

    var canGoBack: Bool { currentStep != Step.allCases.first }

    func canSelect(_ step: Step) -> Bool {
        guard let index = Step.allCases.firstIndex(of: step) else { return false }
        return index <= furthestVisitedIndex
    }

    func select(_ step: Step) {
        guard canSelect(step) else { return }
        currentStep = step
    }

    func advance() {
        guard let index = Step.allCases.firstIndex(of: currentStep),
              Step.allCases.indices.contains(index + 1) else {
            return
        }
        let nextIndex = index + 1
        furthestVisitedIndex = max(furthestVisitedIndex, nextIndex)
        currentStep = Step.allCases[nextIndex]
    }

    func goBack() {
        guard let index = Step.allCases.firstIndex(of: currentStep), index > 0 else {
            return
        }
        currentStep = Step.allCases[index - 1]
    }

    func complete() {
        defaults.set(Self.schemaVersion, forKey: Self.completedVersionKey)
        isCompleted = true
    }

    func reset() {
        defaults.removeObject(forKey: Self.completedVersionKey)
        currentStep = .welcome
        furthestVisitedIndex = 0
        isCompleted = false
    }
}
