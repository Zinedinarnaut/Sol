import SwiftUI
import AppKit

@main
struct SolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = LauncherViewModel()
    @StateObject private var controllerViewModel = ControllerManagerViewModel()

    var body: some Scene {
        Window("Sol", id: "main") {
            RootView(viewModel: viewModel, controllerViewModel: controllerViewModel)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Emulation") {
                Button("Launch Selected Game") {
                    viewModel.launchSelectedGame()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!viewModel.canLaunch)

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
                .disabled(viewModel.isScanning || viewModel.isLaunching)
            }
        }

        Settings {
            LauncherSettingsView(
                viewModel: viewModel,
                controllerViewModel: controllerViewModel
            )
        }
    }
}

struct RootView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var controllerViewModel: ControllerManagerViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var showSplash = true
    @State private var window: NSWindow?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if showSplash {
                SplashView()
                    .transition(.opacity.combined(with: .scale))
            } else {
                LauncherView(viewModel: viewModel, controllerViewModel: controllerViewModel)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .onAppear {
            LauncherAppController.shared.attach(viewModel: viewModel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.6)) {
                    showSplash = false
                }
            }
            controllerViewModel.onNavigate = { action in
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
            viewModel.handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.reconcileEmulationState()
        }
        .onChange(of: viewModel.isLaunchIsolationActive) { _, newValue in
            controllerViewModel.setPollingEnabled(!newValue)
        }
        .onChange(of: viewModel.isSettingsPresented) { _, isPresented in
            guard isPresented else { return }
            openSettings()
            viewModel.isSettingsPresented = false
        }
        .onChange(of: viewModel.isLaunching, initial: true) { _, isLaunching in
            controllerViewModel.setEmulationActive(isLaunching)
            updateWindowTitle()
        }
        .onChange(of: viewModel.session.title) { _, _ in
            updateWindowTitle()
        }
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
            DispatchQueue.main.async { [weak self] in
                self?.fillFullscreenDisplay()
            }
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

    private func fillFullscreenDisplay() {
        guard isEmulationPresentationActive,
              let window,
              window.styleMask.contains(.fullScreen),
              let screen = window.screen else {
            return
        }

        let displayFrame = screen.frame
        guard window.frame != displayFrame else { return }
        window.setFrame(displayFrame, display: true, animate: false)
    }
}
