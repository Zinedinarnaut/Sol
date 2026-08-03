import Foundation
import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Sol")
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(NSMenuItem(title: "Open Sol", action: #selector(openSol), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Launch Last Played", action: #selector(launchLast), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())

        if let snapshot = SharedDataStore.shared.loadSnapshotSync() {
            let games = snapshot.games.sorted { $0.hoursPlayed > $1.hoursPlayed }.prefix(5)
            if !games.isEmpty {
                let header = NSMenuItem(title: "Top Games", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)

                for game in games {
                    let item = NSMenuItem(title: game.title, action: #selector(launchGame(_:)), keyEquivalent: "")
                    item.representedObject = game.id
                    menu.addItem(item)
                }
                menu.addItem(NSMenuItem.separator())
            }
        }

        menu.addItem(NSMenuItem(title: "Rescan Library", action: #selector(rescan), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
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

    @objc private func openSettings() {
        LauncherAppController.shared.openSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
