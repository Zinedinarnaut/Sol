import AppKit
import XCTest
@testable import Sol

final class FullscreenWindowObserverTests: XCTestCase {
    @MainActor
    func testTracksFullscreenNotificationsForOnlyTheObservedWindow() {
        let observedWindow = makeWindow()
        let otherWindow = makeWindow()
        let observer = FullscreenWindowObserver()
        var states: [Bool] = []

        observer.observe(window: observedWindow) { states.append($0) }
        XCTAssertEqual(states, [false])

        NotificationCenter.default.post(
            name: NSWindow.didEnterFullScreenNotification,
            object: otherWindow
        )
        XCTAssertEqual(states, [false])

        NotificationCenter.default.post(
            name: NSWindow.didEnterFullScreenNotification,
            object: observedWindow
        )
        NotificationCenter.default.post(
            name: NSWindow.didExitFullScreenNotification,
            object: observedWindow
        )

        XCTAssertEqual(states, [false, true, false])
        observer.stopObserving()
    }

    @MainActor
    func testMakesLauncherWindowEligibleForPrimaryFullscreen() {
        let window = makeWindow()
        let observer = FullscreenWindowObserver()

        observer.observe(window: window) { _ in }

        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        observer.stopObserving()
    }

    @MainActor
    func testRepeatedObservationDoesNotRepublishUnchangedFullscreenState() {
        let window = makeWindow()
        let observer = FullscreenWindowObserver()
        var initialStates: [Bool] = []
        var updatedStates: [Bool] = []

        observer.observe(window: window) { initialStates.append($0) }
        observer.observe(window: window) { updatedStates.append($0) }

        XCTAssertEqual(initialStates, [false])
        XCTAssertTrue(updatedStates.isEmpty)

        NotificationCenter.default.post(
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )

        XCTAssertEqual(initialStates, [false])
        XCTAssertEqual(updatedStates, [true])
        observer.stopObserving()
    }

    @MainActor
    func testEmulationPresentationHidesToolbarWithoutChangingWindowOrApplicationPresentation() {
        let window = makeWindow()
        window.toolbar = NSToolbar(identifier: "TestToolbar")
        let observer = FullscreenWindowObserver()

        observer.observe(window: window) { _ in }
        let originalFrame = window.frame
        let originalPresentationOptions = NSApp.presentationOptions
        observer.setEmulationPresentationActive(true)

        XCTAssertFalse(window.toolbar?.isVisible ?? true)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertEqual(NSApp.presentationOptions, originalPresentationOptions)

        observer.setEmulationPresentationActive(false)

        XCTAssertTrue(window.toolbar?.isVisible ?? false)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertEqual(NSApp.presentationOptions, originalPresentationOptions)
        observer.stopObserving()
    }

    @MainActor
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}
