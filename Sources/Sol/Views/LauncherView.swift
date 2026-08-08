import SwiftUI
import AppKit

private enum LauncherSection: String, CaseIterable, Identifiable {
    case home
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        }
    }
}

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var controllerViewModel: ControllerManagerViewModel
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedIndex: Int = 0
    @State private var rootSize: CGSize = .zero
    @State private var selectedCardFrame: CGRect = .zero
    @State private var focusPoint: CGPoint = CGPoint(x: 0.5, y: 0.6)
    @State private var backgroundImage: NSImage?
    @State private var previousBackgroundImage: NSImage?
    @State private var backgroundKey: String = ""
    @State private var backgroundFade: Double = 1.0
    @State private var canPlayFocusSound = false
    @State private var searchText = ""
    @State private var section: LauncherSection = .home

    init(viewModel: LauncherViewModel, controllerViewModel: ControllerManagerViewModel) {
        self.viewModel = viewModel
        self.controllerViewModel = controllerViewModel
    }

    var body: some View {
        GeometryReader { proxy in
            let size = LauncherLayout.sanitizedSize(proxy.size)

            ZStack {
                if viewModel.isLaunching {
                    Color.black
                        .ignoresSafeArea()

                    EmbeddedGamePlayerView(viewModel: viewModel)
                        .id(viewModel.embeddedLaunchID)
                        .frame(width: size.width, height: size.height)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    if viewModel.launchActivity.isVisible {
                        GameLaunchOverlayView(
                            viewModel: viewModel,
                            backgroundImage: backgroundImage
                        )
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                        .zIndex(2)
                    }

                    VStack {
                        Spacer(minLength: 0)
                        EmulationControlBar(viewModel: viewModel)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    }
                    .frame(width: size.width, height: size.height)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
                } else {
                    if section == .home {
                        backgroundLayer(size: size)
                            .zIndex(0)

                        let effectiveGamingMode = viewModel.isGamingMode || viewModel.isLaunchIsolationActive
                        MetalBackgroundView(
                            viewSize: size,
                            focusIntensity: focusIntensity,
                            scrollOffset: scrollOffset,
                            focusPoint: focusPoint,
                            backgroundImage: nil,
                            backgroundVersion: 0,
                            isGamingMode: effectiveGamingMode,
                            isLaunchActive: viewModel.isLaunchIsolationActive
                        )
                        .blendMode(.screen)
                        .opacity(0.62)
                        .zIndex(1)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                        LinearGradient(
                            colors: viewModel.games.isEmpty
                                ? [
                                    Color.black.opacity(0.4),
                                    Color.black.opacity(0.08),
                                    Color.clear,
                                ]
                                : [
                                    Color.black.opacity(0.78),
                                    Color.black.opacity(0.28),
                                    Color.clear,
                                ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .zIndex(1.5)

                        homeContent(size: size, isGamingMode: effectiveGamingMode)
                            .zIndex(2)
                    } else {
                        LibraryBrowserView(
                            games: visibleGames,
                            totalGameCount: viewModel.games.count,
                            selectedGame: $viewModel.selectedGame,
                            thumbnailService: viewModel.thumbnailService,
                            isScanning: viewModel.isScanning,
                            statusMessage: libraryStatusMessage,
                            canLaunch: viewModel.canLaunchAnyGame,
                            onLaunch: { viewModel.launchGame(withId: $0.id) },
                            onRevealGame: viewModel.revealGameFile,
                            onRevealMods: viewModel.revealModsDirectory,
                            onRevealSDMods: viewModel.revealSDCardModsDirectory,
                            onRevealGameData: viewModel.revealGameDataDirectory
                        )
                        .frame(width: size.width, height: size.height)
                        .zIndex(2)
                    }
                }
            }
            .onAppear {
                rootSize = size
                updateFocusPoint()
            }
            .onChange(of: size) { _, newSize in
                rootSize = newSize
                updateFocusPoint()
            }
        }
        .coordinateSpace(name: "solRoot")
        .onChange(of: viewModel.selectedGame?.id) { _, _ in
            updateSelectedIndex()
            if canPlayFocusSound, !viewModel.isScanning {
                SoundPlayer.shared.play(.focus)
            }
        }
        .onChange(of: viewModel.games.count) { _, _ in
            updateSelectedIndex()
        }
        .onChange(of: selectedIndex) { _, _ in
            Task { await updateBackground() }
        }
        .onAppear {
            updateSelectedIndex()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                canPlayFocusSound = true
            }
        }
        .onPreferenceChange(SelectedCardFramePreferenceKey.self) { frame in
            if frame != .zero {
                selectedCardFrame = frame
                updateFocusPoint()
            }
        }
        .task(id: viewModel.selectedGame?.id) {
            await updateBackground()
        }
        .task {
            await viewModel.updateService.checkForUpdates()
        }
        .sheet(isPresented: $viewModel.isAmiiboPickerPresented) {
            AmiiboPickerView(viewModel: viewModel)
        }
        .toolbar {
            LauncherToolbar(
                viewModel: viewModel,
                searchText: $searchText,
                section: $section
            )
        }
        .userActivity("com.solemu.app.game", isActive: viewModel.selectedGame != nil) { activity in
            let selected = viewModel.selectedGame
            activity.title = selected?.title ?? "Sol"
            activity.userInfo = [
                "gameId": selected?.id ?? "",
                "title": selected?.title ?? ""
            ]
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = true
            #if os(iOS)
            activity.isEligibleForPrediction = true
            #endif
        }
    }

    private var focusIntensity: CGFloat {
        guard !viewModel.games.isEmpty else { return 0.05 }
        let base: CGFloat = viewModel.selectedGame == nil ? 0.08 : 0.14
        let indexBoost = CGFloat(selectedIndex % 5) * 0.015
        let gamingScale: CGFloat = (viewModel.isGamingMode || viewModel.isLaunchIsolationActive) ? 0.75 : 1.0
        return min(0.3, (base + indexBoost) * gamingScale)
    }

    private var visibleGames: [Game] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.games }

        return viewModel.games.filter { game in
            game.title.localizedCaseInsensitiveContains(query) ||
                game.titleId?.localizedCaseInsensitiveContains(query) == true ||
                game.fileURL.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    private func homeContent(size: CGSize, isGamingMode: Bool) -> some View {
        VStack(spacing: 0) {
            selectedGameHero(size: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            if !viewModel.games.isEmpty {
                GameCarouselView(
                    games: visibleGames,
                    totalGameCount: viewModel.games.count,
                    selectedGame: $viewModel.selectedGame,
                    thumbnailService: viewModel.thumbnailService,
                    scrollOffset: $scrollOffset,
                    isGamingMode: isGamingMode,
                    isScanning: viewModel.isScanning,
                    isLaunching: viewModel.isLaunching,
                    statusMessage: libraryStatusMessage,
                    onLaunch: { viewModel.launchGame(withId: $0.id) },
                    onRevealGame: viewModel.revealGameFile,
                    onRevealMods: viewModel.revealModsDirectory,
                    onRevealSDMods: viewModel.revealSDCardModsDirectory,
                    onRevealGameData: viewModel.revealGameDataDirectory
                )
                .frame(maxWidth: .infinity)
                .frame(height: GameCarouselView.preferredHeight)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func selectedGameHero(size: CGSize) -> some View {
        if let game = viewModel.selectedGame {
            HStack(alignment: .bottom, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Ready to Play", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())

                    Text(game.title)
                        .font(.system(size: min(max(size.width * 0.032, 30), 48), weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .accessibilityAddTraits(.isHeader)

                    HStack(spacing: 8) {
                        Label(game.formattedPlaytime, systemImage: "clock")

                        if let lastPlayed = game.formattedLastPlayed {
                            Text("•")
                                .foregroundStyle(.tertiary)
                            Text("Played \(lastPlayed)")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)

                    heroActions(game)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .shadow(color: .black.opacity(0.42), radius: 14, y: 4)

                Spacer(minLength: 12)

                if size.width >= 900, size.height >= 650 {
                    ThumbnailView(
                        game: game,
                        service: viewModel.thumbnailService,
                        targetSize: CGSize(width: 132, height: 185)
                    )
                    .frame(width: 132, height: 185)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, max(34, min(64, size.width * 0.045)))
            .padding(.bottom, max(24, min(44, size.height * 0.045)))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 18) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white, Color.orange)
                    .frame(width: 72, height: 72)
                    .background(.thinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)

                VStack(spacing: 7) {
                    Text("Set Up Your Library")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)

                    Text(
                        viewModel.statusMessage
                            ?? "Choose the folder containing your own game backups. Sol scans it locally."
                    )
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                }

                HStack(spacing: 10) {
                    SettingsLink {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: viewModel.rescan) {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.isScanning)
                }
            }
            .padding(.horizontal, 42)
            .padding(.vertical, 34)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 36, y: 18)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func heroActions(_ game: Game) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                heroActionControls(game)
            }
        } else {
            heroActionControls(game)
        }
    }

    private func heroActionControls(_ game: Game) -> some View {
        HStack(spacing: 8) {
            heroLaunchButton(game)

            gameOptionsMenu(game)
                .menuIndicator(.hidden)
                .controlSize(.large)
                .modifier(NativeSecondaryActionButton())
                .help("More options for \(game.title)")
        }
    }

    @ViewBuilder
    private func heroLaunchButton(_ game: Game) -> some View {
        let button = Button {
            viewModel.launchGame(withId: game.id)
        } label: {
            Label(viewModel.isLaunching ? "Launching…" : "Play", systemImage: "play.fill")
                .frame(minWidth: 92)
        }
        .controlSize(.large)
        .disabled(!viewModel.canLaunch)
        .help("Launch \(game.title)")
        .keyboardShortcut(.return, modifiers: [])
        .buttonBorderShape(.capsule)

        if #available(macOS 26.0, *) {
            button
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private func gameOptionsMenu(_ game: Game) -> some View {
        Menu {
            Button("Show Game in Finder", systemImage: "folder") {
                viewModel.revealGameFile(game)
            }

            Divider()

            Button("Open Mods Folder", systemImage: "shippingbox") {
                viewModel.revealModsDirectory(for: game)
            }
            Button("Open SD Card Mods", systemImage: "sdcard") {
                viewModel.revealSDCardModsDirectory(for: game)
            }
            Button("Open Game Data", systemImage: "internaldrive") {
                viewModel.revealGameDataDirectory(for: game)
            }
        } label: {
            Label("More Game Options", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .accessibilityLabel("More Game Options")
    }

    private var libraryStatusMessage: String? {
        guard !searchText.isEmpty, visibleGames.isEmpty else {
            return viewModel.statusMessage
        }
        return "No games match “\(searchText)”"
    }

    private func updateSelectedIndex() {
        if let selected = viewModel.selectedGame,
           let index = viewModel.games.firstIndex(where: { $0.id == selected.id }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
    }

    private func updateFocusPoint() {
        guard rootSize.width > 0, rootSize.height > 0 else { return }
        guard selectedCardFrame != .zero else {
            focusPoint = CGPoint(x: 0.5, y: 0.65)
            return
        }
        let x = selectedCardFrame.midX / rootSize.width
        let y = selectedCardFrame.midY / rootSize.height
        focusPoint = CGPoint(x: min(max(x, 0.05), 0.95), y: min(max(y, 0.05), 0.95))
    }

    private func updateBackground() async {
        let targetGame: Game? = {
            if let selected = viewModel.selectedGame { return selected }
            if viewModel.games.indices.contains(selectedIndex) { return viewModel.games[selectedIndex] }
            return viewModel.games.first
        }()
        guard let game = targetGame else {
            await MainActor.run {
                previousBackgroundImage = nil
                backgroundImage = nil
                backgroundFade = 1.0
                backgroundKey = ""
            }
            return
        }

        let key = game.titleId ?? game.title
        await MainActor.run {
            backgroundKey = key
        }

        let image = await viewModel.thumbnailService.fetchBackground(for: game)
        await MainActor.run {
            guard backgroundKey == key else { return }
            previousBackgroundImage = backgroundImage
            backgroundImage = image
            backgroundFade = 0.0
            withAnimation(.easeInOut(duration: 0.65)) {
                backgroundFade = 1.0
            }
        }
    }

    private func backgroundLayer(size: CGSize) -> some View {
        let overscan: CGFloat = 44

        return ZStack {
            if let previousBackgroundImage {
                backgroundImageView(previousBackgroundImage, size: size, overscan: overscan)
                    .opacity(1.0 - backgroundFade)
            }
            if let backgroundImage {
                backgroundImageView(backgroundImage, size: size, overscan: overscan)
                    .opacity(backgroundFade)
            }
            if backgroundImage == nil && previousBackgroundImage == nil {
                Theme.background
            }
        }
        .frame(
            width: size.width + overscan * 2,
            height: size.height + overscan * 2
        )
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func backgroundImageView(
        _ image: NSImage,
        size: CGSize,
        overscan: CGFloat
    ) -> some View {
        let parallax = min(max(scrollOffset / 1400, -12), 12)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(
                width: size.width + overscan * 2,
                height: size.height + overscan * 2
            )
            .blur(radius: 2.25)
            .saturation(0.96)
            .contrast(1.02)
            .scaleEffect(1.018)
            .overlay(Color.black.opacity(0.24))
            .offset(x: parallax)
    }
}

enum LauncherLayout {
    static func sanitizedSize(_ proposed: CGSize) -> CGSize {
        CGSize(
            width: proposed.width.isFinite ? max(1, proposed.width) : 1,
            height: proposed.height.isFinite ? max(1, proposed.height) : 1
        )
    }
}

private struct LauncherToolbar: ToolbarContent {
    @ObservedObject var viewModel: LauncherViewModel
    @Binding var searchText: String
    @Binding var section: LauncherSection

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            if !viewModel.isLaunching {
                ToolbarItem(
                    id: "sol.library.section",
                    placement: .navigation
                ) {
                    sectionPicker
                }

                ToolbarItem(
                    id: "sol.library.search",
                    placement: .automatic
                ) {
                    librarySearchField
                }

                ToolbarSpacer(.flexible, placement: .primaryAction)
            }

            if viewModel.isLaunching {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: viewModel.toggleEmulationPause) {
                        Label(
                            viewModel.session.isPaused ? "Resume" : "Pause",
                            systemImage: viewModel.session.isPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .help(viewModel.session.isPaused ? "Resume emulation" : "Pause emulation")

                    Button(action: viewModel.toggleEmulationFullscreen) {
                        Label(
                            viewModel.session.isFullscreen ? "Exit Full Screen" : "Full Screen",
                            systemImage: viewModel.session.isFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                    .help(viewModel.session.isFullscreen ? "Exit full screen" : "Enter full screen")
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive, action: viewModel.stopLaunch) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop the active game")
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if !viewModel.isLaunching {
                    UpdateToolbarButton(service: viewModel.updateService)

                    Button(action: viewModel.rescan) {
                        Label(
                            viewModel.isScanning ? "Scanning…" : "Rescan Library",
                            systemImage: "arrow.clockwise"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .disabled(viewModel.isScanning)
                    .help(viewModel.isScanning ? "Scanning the game library" : "Rescan the game library")
                }

                ProfileMenuView(viewModel: viewModel)
            }
        } else {
            if !viewModel.isLaunching {
                ToolbarItem(placement: .navigation) {
                    sectionPicker
                }

                ToolbarItem(placement: .principal) {
                    librarySearchField
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isLaunching {
                    Button(action: viewModel.toggleEmulationPause) {
                        Label(
                            viewModel.session.isPaused ? "Resume" : "Pause",
                            systemImage: viewModel.session.isPaused ? "play.fill" : "pause.fill"
                        )
                    }

                    Button(action: viewModel.toggleEmulationFullscreen) {
                        Label(
                            viewModel.session.isFullscreen ? "Exit Full Screen" : "Full Screen",
                            systemImage: viewModel.session.isFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }

                    Button(role: .destructive, action: viewModel.stopLaunch) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    UpdateToolbarButton(service: viewModel.updateService)

                    Button(action: viewModel.rescan) {
                        Label(
                            viewModel.isScanning ? "Scanning…" : "Rescan Library",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(viewModel.isScanning)
                }

                ProfileMenuView(viewModel: viewModel)
            }
        }
    }

    private var librarySearchField: some View {
        NativeToolbarSearchField(
            text: $searchText,
            placeholder: "Search Library"
        )
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 540)
        .layoutPriority(1)
    }

    private var sectionPicker: some View {
        Picker("View", selection: $section) {
            ForEach(LauncherSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .labelStyle(.iconOnly)
                    .tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .help("Switch between Home and Library")
    }
}

private struct UpdateToolbarButton: View {
    @ObservedObject var service: GitHubUpdateService

    var body: some View {
        Group {
            switch service.state {
            case let .available(release):
                Button {
                    Task { await service.downloadAvailableUpdate() }
                } label: {
                    Label(
                        "Update to \(release.version?.description ?? release.tagName)",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .labelStyle(.iconOnly)
                }
                .help("Download \(release.name ?? release.tagName) from GitHub")
            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .help("Downloading and verifying the Sol update")
            case let .ready(release, _):
                Button(action: service.openReadyUpdate) {
                    Label(
                        "Open \(release.version?.description ?? release.tagName) Installer",
                        systemImage: "shippingbox.fill"
                    )
                    .labelStyle(.iconOnly)
                }
                .help("Open the verified Sol disk image")
            default:
                EmptyView()
            }
        }
    }
}

private struct NativeSecondaryActionButton: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
    }
}
