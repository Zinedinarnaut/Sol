import Foundation
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBar = StatusBarController()
    private var dockGames: [SharedGameRecord] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyManager.shared.registerDefaultHotKeys()
        refreshDockGames()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SolEngineEmbeddedRuntime.shared.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        LauncherAppController.shared.activateApp()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        refreshDockGames()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Sol", action: #selector(openSol), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Launch Last Played", action: #selector(launchLast), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        for game in dockGames {
            let item = NSMenuItem(title: game.title, action: #selector(launchGame(_:)), keyEquivalent: "")
            item.representedObject = game.id
            menu.addItem(item)
        }
        if !dockGames.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        menu.addItem(NSMenuItem(title: "Rescan Library", action: #selector(rescan), keyEquivalent: ""))
        return menu
    }

    private func refreshDockGames() {
        SharedDataStore.shared.loadSnapshot { [weak self] snapshot in
            let games = Array(
                (snapshot?.games ?? [])
                    .sorted { $0.hoursPlayed > $1.hoursPlayed }
                    .prefix(5)
            )
            Task { @MainActor [weak self] in
                self?.dockGames = games
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        LauncherAppController.shared.open(url: url)
    }

    @objc private func openSol() {
        LauncherAppController.shared.activateApp()
    }

    @objc private func launchLast() {
        LauncherAppController.shared.launchLastPlayed()
    }

    @objc private func launchGame(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        LauncherAppController.shared.launchGame(id: id)
    }

    @objc private func rescan() {
        LauncherAppController.shared.rescan()
    }
}
