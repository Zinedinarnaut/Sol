import Foundation
import XCTest
@testable import Sol

@MainActor
final class SolOnboardingStoreTests: XCTestCase {
    func testSetupMigratesLegacyIdentityWithoutOverwritingCustomNames() {
        XCTAssertEqual(
            SolOnboardingIdentityPolicy.initialDisplayName("RyuPlayer"),
            "Sol Player"
        )
        XCTAssertEqual(
            SolOnboardingIdentityPolicy.initialDisplayName("Zinedin"),
            "Zinedin"
        )
    }

    func testFirstRunStartsAtWelcomeAndPersistsCompletion() throws {
        let suiteName = "SolOnboardingStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let options = try SolLaunchOptions.parse([])
        let store = SolOnboardingStore(defaults: defaults, launchOptions: options)
        XCTAssertFalse(store.isCompleted)
        XCTAssertEqual(store.currentStep, .welcome)

        store.complete()

        let reloaded = SolOnboardingStore(defaults: defaults, launchOptions: options)
        XCTAssertTrue(reloaded.isCompleted)
    }

    func testOnlyVisitedStepsCanBeSelectedDirectly() throws {
        let suiteName = "SolOnboardingStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let options = try SolLaunchOptions.parse(["--show-onboarding"])
        let store = SolOnboardingStore(
            defaults: defaults,
            launchOptions: options
        )

        XCTAssertTrue(store.canSelect(.welcome))
        XCTAssertFalse(store.canSelect(.library))

        store.advance()
        XCTAssertTrue(store.canSelect(.account))
        XCTAssertFalse(store.canSelect(.library))
    }

    func testResetLaunchOptionClearsACompletedSetup() throws {
        let suiteName = "SolOnboardingStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialStore = SolOnboardingStore(
            defaults: defaults,
            launchOptions: try SolLaunchOptions.parse([])
        )
        initialStore.complete()

        let resetStore = SolOnboardingStore(
            defaults: defaults,
            launchOptions: try SolLaunchOptions.parse(["--reset-onboarding"])
        )
        XCTAssertFalse(resetStore.isCompleted)
        XCTAssertEqual(resetStore.currentStep, .welcome)
    }

    func testLaunchOptionsIgnoreAppKitAndXcodeArguments() {
        let options = SolLaunchOptions.current(
            arguments: ["-NSDocumentRevisionsDebugMode", "YES", "--show-onboarding"]
        )

        XCTAssertTrue(options.showOnboarding)
        XCTAssertFalse(options.resetOnboarding)
    }

    func testLauncherAccessStaysBlockedUntilSetupAndSplashFinish() {
        XCTAssertFalse(
            SolLauncherAccessPolicy.allowsLauncherInteraction(
                setupCompleted: false,
                splashVisible: false
            )
        )
        XCTAssertFalse(
            SolLauncherAccessPolicy.allowsLauncherInteraction(
                setupCompleted: true,
                splashVisible: true
            )
        )
        XCTAssertTrue(
            SolLauncherAccessPolicy.allowsLauncherInteraction(
                setupCompleted: true,
                splashVisible: false
            )
        )
    }

    func testControllerNavigationStaysBlockedDuringSetupAndGameIsolation() {
        XCTAssertFalse(
            SolLauncherAccessPolicy.allowsControllerNavigation(
                setupCompleted: false,
                splashVisible: false,
                launchIsolationActive: false
            )
        )
        XCTAssertFalse(
            SolLauncherAccessPolicy.allowsControllerNavigation(
                setupCompleted: true,
                splashVisible: false,
                launchIsolationActive: true
            )
        )
        XCTAssertTrue(
            SolLauncherAccessPolicy.allowsControllerNavigation(
                setupCompleted: true,
                splashVisible: false,
                launchIsolationActive: false
            )
        )
    }
}
