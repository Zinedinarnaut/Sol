import SwiftUI
import AppKit
import WhatsNewKit

@main
struct SolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = LauncherViewModel()
    @StateObject private var controllerViewModel = ControllerManagerViewModel()
    @StateObject private var friendsStore = SolFriendsStore()
    @StateObject private var onboardingStore = SolOnboardingStore()

    var body: some Scene {
        Window("Sol", id: "main") {
            RootView(
                viewModel: viewModel,
                controllerViewModel: controllerViewModel,
                friendsStore: friendsStore,
                onboardingStore: onboardingStore
            )
        }
        .windowToolbarStyle(.unified)
        .commands {
            SolSettingsCommands()

            CommandMenu("Emulation") {
                Button("Launch Selected Game") {
                    viewModel.launchSelectedGame()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!viewModel.isLauncherInteractionEnabled || !viewModel.canLaunch)

                Button("Stop Emulation") {
                    viewModel.stopLaunch()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!viewModel.isLaunching)

                Divider()

                Button(viewModel.session.isPaused ? "Resume Emulation" : "Pause Emulation") {
                    viewModel.toggleEmulationPause()
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(!viewModel.isLaunching)

                Button(viewModel.session.isFullscreen ? "Exit Game Full Screen" : "Enter Game Full Screen") {
                    viewModel.toggleEmulationFullscreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(!viewModel.isLaunching)

                Button("Take Screenshot") {
                    viewModel.takeScreenshot()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!viewModel.isLaunching)

                Divider()

                Button("Rescan Library") {
                    viewModel.rescan()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(
                    !viewModel.isLauncherInteractionEnabled ||
                    viewModel.isScanning ||
                    viewModel.isLaunching
                )
            }
        }

        Window("Settings", id: "settings") {
            LauncherSettingsView(
                viewModel: viewModel,
                controllerViewModel: controllerViewModel,
                friendsStore: friendsStore,
                onboardingStore: onboardingStore
            )
        }
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1_020, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct SolSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}

struct RootView: View {
    @ObservedObject var viewModel: LauncherViewModel
    // RootView only sends commands to this object; it does not render any of
    // its published controller snapshots. Keeping it as a plain reference
    // prevents 12.5 Hz input polling from invalidating the entire launcher.
    let controllerViewModel: ControllerManagerViewModel
    @ObservedObject var friendsStore: SolFriendsStore
    @ObservedObject var onboardingStore: SolOnboardingStore
    @Environment(\.openWindow) private var openWindow
    @State private var showSplash = true
    @State private var window: NSWindow?
    @State private var whatsNew: WhatsNew?
    @State private var shouldOfferWhatsNew = false

    var body: some View {
        ZStack {
            Group {
                if viewModel.isLaunching {
                    Color.black
                } else {
                    Theme.background
                }
            }
            .ignoresSafeArea()

            if showSplash {
                SplashView()
                    .transition(.opacity.combined(with: .scale))
            } else if !onboardingStore.isCompleted {
                SolOnboardingView(
                    viewModel: viewModel,
                    store: onboardingStore,
                    friendsStore: friendsStore
                )
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                LauncherView(
                    viewModel: viewModel,
                    friendsStore: friendsStore
                )
                    .transition(.opacity.combined(with: .scale))
            }
        }
        // During gameplay the CAMetalLayer must be proposed the complete
        // display size, including the horizontal display-cutout safe area.
        // Controls still apply their own padding inside LauncherView.
        .ignoresSafeArea(
            .container,
            edges: viewModel.isLaunching ? .all : []
        )
        .onAppear {
            shouldOfferWhatsNew = onboardingStore.isCompleted
            synchronizeLauncherInteraction()
            LauncherAppController.shared.attach(viewModel: viewModel)
            friendsStore.onPersistedChange = { [weak viewModel] in
                viewModel?.profileDataDidChange()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.6)) {
                    showSplash = false
                }
                guard shouldOfferWhatsNew else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    whatsNew = SolWhatsNew.current
                }
            }
            controllerViewModel.onNavigate = { action in
                guard viewModel.isLauncherInteractionEnabled,
                      !viewModel.isLaunchIsolationActive else { return }
                switch action {
                case .next:
                    viewModel.selectNextGame()
                case .previous:
                    viewModel.selectPreviousGame()
                case .launch:
                    viewModel.launchSelectedGame()
                case .openSettings:
                    viewModel.isSettingsPresented = true
                }
            }
        }
        .onOpenURL { url in
            LauncherAppController.shared.open(url: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.reconcileEmulationState()
        }
        .onReceive(viewModel.$backendProfiles) { profiles in
            guard let activeProfile = profiles.first(where: \.isDefault)
                    ?? profiles.first else {
                return
            }
            friendsStore.synchronizeActiveGameUser(
                displayName: activeProfile.name
            )
        }
        .onChange(of: viewModel.isLaunchIsolationActive) { _, _ in
            synchronizeLauncherInteraction()
        }
        .onChange(of: viewModel.isSettingsPresented) { _, isPresented in
            guard isPresented else { return }
            openWindow(id: "settings")
            viewModel.isSettingsPresented = false
        }
        .onChange(of: viewModel.isLaunching, initial: true) { _, isLaunching in
            controllerViewModel.setEmulationActive(isLaunching)
            updateWindowTitle()
            if !isLaunching {
                LauncherAppController.shared
                    .launcherInteractionDidBecomeAvailable()
            }
        }
        .onChange(of: viewModel.session.title) { _, _ in
            updateWindowTitle()
        }
        .onChange(of: viewModel.cloudSync.lastRestoreID) { _, _ in
            friendsStore.reload()
        }
        .onChange(of: onboardingStore.isCompleted) { _, completed in
            synchronizeLauncherInteraction()
            LauncherAppController.shared
                .launcherInteractionDidBecomeAvailable()
            guard completed else { return }
            updateWindowTitle()
            viewModel.reconcileEmulationState()
        }
        .onChange(of: viewModel.games.map(\.id)) { _, _ in
            LauncherAppController.shared
                .launcherInteractionDidBecomeAvailable()
        }
        .onChange(of: viewModel.isScanning) { _, isScanning in
            guard !isScanning else { return }
            LauncherAppController.shared
                .launcherInteractionDidBecomeAvailable()
        }
        .onChange(of: viewModel.solEngineValidation.isValid) { _, isValid in
            guard isValid else { return }
            LauncherAppController.shared
                .launcherInteractionDidBecomeAvailable()
        }
        .onChange(of: viewModel.gamesValidation.isValid) { _, isValid in
            guard isValid else { return }
            LauncherAppController.shared
                .launcherInteractionDidBecomeAvailable()
        }
        .onChange(of: showSplash) { _, isVisible in
            synchronizeLauncherInteraction()
            if !isVisible {
                LauncherAppController.shared
                    .launcherInteractionDidBecomeAvailable()
            }
        }
        .sheet(
            whatsNew: $whatsNew,
            versionStore: UserDefaultsWhatsNewVersionStore()
        )
        .background(
            WindowAccessor(
                window: $window,
                isEmulationActive: viewModel.isLaunching,
                onWindowReady: { hostWindow in
                    viewModel.onFullscreenRequest = { [weak hostWindow] fullscreen in
                        DispatchQueue.main.async {
                            guard let hostWindow,
                                  hostWindow.styleMask.contains(.fullScreen) != fullscreen else {
                                return
                            }
                            hostWindow.toggleFullScreen(nil)
                        }
                    }
                },
                onFullscreenChange: viewModel.hostFullscreenDidChange
            )
        )
    }

    private func updateWindowTitle() {
        guard let window else { return }

        if viewModel.isLaunching {
            let gameTitle = viewModel.session.title ?? viewModel.selectedGame?.title
            window.title = gameTitle.map { "\($0) — Sol" } ?? "Sol"
        } else {
            window.title = "Sol"
        }
    }

    private func synchronizeLauncherInteraction() {
        let launcherEnabled = SolLauncherAccessPolicy.allowsLauncherInteraction(
            setupCompleted: onboardingStore.isCompleted,
            splashVisible: showSplash
        )
        viewModel.setLauncherInteractionEnabled(launcherEnabled)
        controllerViewModel.setPollingEnabled(
            SolLauncherAccessPolicy.allowsControllerNavigation(
                setupCompleted: onboardingStore.isCompleted,
                splashVisible: showSplash,
                launchIsolationActive: viewModel.isLaunchIsolationActive
            )
        )
    }
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    let isEmulationActive: Bool
    let onWindowReady: (NSWindow) -> Void
    let onFullscreenChange: (Bool) -> Void

    func makeCoordinator() -> FullscreenWindowObserver {
        FullscreenWindowObserver()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        attachWindow(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attachWindow(from: nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: FullscreenWindowObserver) {
        coordinator.stopObserving()
    }

    private func attachWindow(from view: NSView, coordinator: FullscreenWindowObserver) {
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let window = view?.window, let coordinator else { return }
            self.window = window
            window.title = "Sol"
            onWindowReady(window)
            coordinator.observe(window: window, onFullscreenChange: onFullscreenChange)
            coordinator.setEmulationPresentationActive(isEmulationActive)
        }
    }
}

@MainActor
final class FullscreenWindowObserver: NSObject {
    private weak var window: NSWindow?
    private var onFullscreenChange: ((Bool) -> Void)?
    private var isEmulationPresentationActive = false
    private var previousToolbarVisibility: Bool?
    private var previousTitleVisibility: NSWindow.TitleVisibility?

    func observe(window: NSWindow, onFullscreenChange: @escaping (Bool) -> Void) {
        self.onFullscreenChange = onFullscreenChange

        guard self.window !== window else {
            return
        }

        stopObserving()
        self.window = window
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(fullscreenStateDidChange),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(fullscreenStateDidChange),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        publishCurrentState()
    }

    func setEmulationPresentationActive(_ active: Bool) {
        guard let window, active != isEmulationPresentationActive else {
            return
        }

        isEmulationPresentationActive = active
        if active {
            previousToolbarVisibility = window.toolbar?.isVisible
            previousTitleVisibility = window.titleVisibility
            window.toolbar?.isVisible = false
            window.titleVisibility = .hidden
        } else {
            window.toolbar?.isVisible = previousToolbarVisibility ?? true
            window.titleVisibility = previousTitleVisibility ?? .visible
            previousToolbarVisibility = nil
            previousTitleVisibility = nil
        }
    }

    func stopObserving() {
        setEmulationPresentationActive(false)
        NotificationCenter.default.removeObserver(self)
        window = nil
    }

    @objc private func fullscreenStateDidChange(_ notification: Notification) {
        switch notification.name {
        case NSWindow.didEnterFullScreenNotification:
            onFullscreenChange?(true)
        case NSWindow.didExitFullScreenNotification:
            onFullscreenChange?(false)
        default:
            publishCurrentState()
        }
    }

    private func publishCurrentState() {
        guard let window else { return }
        onFullscreenChange?(window.styleMask.contains(.fullScreen))
    }
}
