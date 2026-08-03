import Foundation
import AppKit

@MainActor
final class LauncherAppController {
    static let shared = LauncherAppController()

    weak var viewModel: LauncherViewModel?

    private init() {}

    func attach(viewModel: LauncherViewModel) {
        self.viewModel = viewModel
    }

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func openSettings() {
        viewModel?.isSettingsPresented = true
        activateApp()
    }

    func rescan() {
        viewModel?.rescan()
        activateApp()
    }

    func launchLastPlayed() {
        guard let viewModel else { return }
        if let snapshot = SharedDataStore.shared.loadSnapshotSync(),
           let id = snapshot.lastLaunchedId ?? snapshot.games.sorted(by: { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }).first?.id {
            viewModel.launchGame(withId: id)
        } else {
            activateApp()
        }
    }

    func launchGame(id: String) {
        viewModel?.launchGame(withId: id)
    }

    func launchGame(path: String) {
        if let viewModel {
            viewModel.launchGame(atPath: path)
        } else {
            SharedDataStore.shared.setPendingLaunch(path: path)
            activateApp()
        }
    }
}
