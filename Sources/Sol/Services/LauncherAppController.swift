import Foundation
import AppKit

@MainActor
final class LauncherAppController {
    static let shared = LauncherAppController()

    weak var viewModel: LauncherViewModel?
    private var pendingNavigationURL: URL?
    private var lastURLLaunchRequest: SharedPendingLaunchRequest?
    private let duplicateURLDeliveryWindow: TimeInterval = 1

    private init() {}

    func attach(viewModel: LauncherViewModel) {
        self.viewModel = viewModel
        launcherInteractionDidBecomeAvailable()
    }

    func activateApp() {
        // `NSApp.windows.first` is not stable once SwiftUI has created the
        // settings scene or a full-screen auxiliary window. Prefer the main
        // gameplay/library window and explicitly move it to the active Space
        // when Sol is reopened from the Dock, menu bar, or a deep link.
        let mainWindow = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { window in
                window.canBecomeKey && window.title == "Sol"
            })
            ?? NSApp.windows.first(where: \.canBecomeKey)

        NSApp.activate(ignoringOtherApps: true)
        guard let mainWindow else { return }
        mainWindow.collectionBehavior.insert(.moveToActiveSpace)
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.orderFrontRegardless()
    }

    func openSettings() {
        viewModel?.isSettingsPresented = true
        activateApp()
    }

    func rescan() {
        viewModel?.rescan()
        activateApp()
    }

    func launcherInteractionDidBecomeAvailable() {
        guard let viewModel,
              viewModel.isLauncherInteractionEnabled else { return }

        if let pendingNavigationURL {
            self.pendingNavigationURL = nil
            viewModel.handleDeepLink(pendingNavigationURL)
        }

        guard !viewModel.isLaunching else { return }
        viewModel.handlePendingLaunchIfNeeded()
    }

    func launchLastPlayed() {
        if let snapshot = SharedDataStore.shared.loadSnapshotSync(),
           let id = snapshot.lastLaunchedId ?? snapshot.games.sorted(by: { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }).first?.id {
            launchGame(id: id)
        } else {
            activateApp()
        }
    }

    func launchGame(id: String) {
        guard let request = SharedPendingLaunchRequest(id: id) else { return }
        enqueueOrDispatch(request)
    }

    func launchGame(path: String) {
        guard let request = SharedPendingLaunchRequest(path: path) else { return }
        enqueueOrDispatch(request)
    }

    func open(url: URL) {
        if let request = SharedPendingLaunchRequest(url: url) {
            if let previous = lastURLLaunchRequest,
               request.duplicates(
                   previous,
                   within: duplicateURLDeliveryWindow
               ) {
                activateApp()
                return
            }

            lastURLLaunchRequest = request
            enqueueOrDispatch(request)
            return
        }

        guard url.scheme?.lowercased() == "sol" else {
            activateApp()
            return
        }

        if let viewModel, viewModel.isLauncherInteractionEnabled {
            viewModel.handleDeepLink(url)
        } else {
            pendingNavigationURL = url
        }
        activateApp()
    }

    private func enqueueOrDispatch(_ request: SharedPendingLaunchRequest) {
        if let viewModel, canDispatch(request, to: viewModel) {
            dispatch(request, to: viewModel)
            activateApp()
            return
        }

        SharedDataStore.shared.setPendingLaunch(request) { [weak self] in
            Task { @MainActor [weak self] in
                self?.launcherInteractionDidBecomeAvailable()
            }
        }
        activateApp()
    }

    private func canDispatch(
        _ request: SharedPendingLaunchRequest,
        to viewModel: LauncherViewModel
    ) -> Bool {
        guard viewModel.isLauncherInteractionEnabled,
              !viewModel.isLaunching,
              viewModel.solEngineValidation.isValid else {
            return false
        }

        switch request.target {
        case .id(let id):
            return !viewModel.isScanning &&
                viewModel.games.contains(where: { $0.id == id }) &&
                viewModel.canLaunchAnyGame
        case .path(let path):
            if viewModel.games.contains(where: {
                $0.fileURL.standardizedFileURL.path == path
            }) {
                return !viewModel.isScanning && viewModel.canLaunchAnyGame
            }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    private func dispatch(
        _ request: SharedPendingLaunchRequest,
        to viewModel: LauncherViewModel
    ) {
        switch request.target {
        case .id(let id):
            viewModel.launchGame(withId: id)
        case .path(let path):
            viewModel.launchGame(atPath: path)
        }
    }
}
