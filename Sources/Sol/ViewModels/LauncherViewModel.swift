import Foundation
import Combine
import AppKit

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var games: [Game] = []
    @Published var selectedGame: Game?
    @Published var consoleLines: [ConsoleLine] = []
    @Published var isScanning = false
    @Published var isLaunching = false
    @Published private(set) var embeddedLaunchID: UUID?
    @Published var session = SolEngineSessionSnapshot()
    @Published var launchActivity = SolEngineLaunchActivity()
    @Published var backendStatus = SolEngineBackendStatus()
    @Published var dlsmProviderStatus = DLSMProviderStatus()
    @Published var backendInputDevices: [SolEngineInputDevice] = []
    @Published var backendControllerMappings: [SolEnginePlayerIndex: SolEngineControllerMapping] = [:]
    @Published var backendProfiles: [SolEngineProfile] = []
    @Published var isBackendOperationRunning = false
    @Published var solEngineValidation = ValidationResult.invalid(message: "Checking bundled Sol Engine core")
    @Published var gamesValidation = ValidationResult.invalid(message: "Select games directory")
    @Published var statusMessage: String?
    @Published var isSettingsPresented = false
    @Published var isAmiiboPickerPresented = false
    @Published var isAmiiboScanPending = false
    @Published var amiiboStatusMessage: String?
    @Published var isGamingMode = false {
        didSet {
            gamingModeService.setFullscreenActive(isGamingMode)
        }
    }
    @Published var isLaunchIsolationActive = false {
        didSet {
            gamingModeService.setLaunchActive(isLaunchIsolationActive)
        }
    }

    let settings: SettingsStore
    let thumbnailService: ThumbnailService
    let solEngineConfiguration: SolEngineConfigurationStore
    let iCloudProfileSync: ICloudProfileSyncService
    let appleAccount: AppleAccountService
    let updateService: GitHubUpdateService
    private(set) var embeddedRenderView = SolEngineRenderView()

    private let pathResolver: SolEnginePathResolver
    private let metadataService: SolEngineMetadataService
    private let scannerService: GameScannerService
    private let embeddedRuntime: SolEngineEmbeddedRuntime
    private let backendService: SolEngineBackendService
    private let dataMigrationService = SolEngineDataMigrationService()
    private let gamingModeService = GamingModeService()
    private let notificationService = NotificationService()
    private let spotlightService = SpotlightIndexService()
    private let sharedStore = SharedDataStore.shared
    private var solEnginePaths: SolEnginePaths?
    private var cancellables = Set<AnyCancellable>()
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var isPendingLaunchCheckInFlight = false
    private var pendingEmbeddedLaunch: PendingEmbeddedLaunch?
    private var isAttachingEmbeddedSurface = false
    private var stopWatchdogTask: Task<Void, Never>?
    private var playtimeRefreshTask: Task<Void, Never>?
    private var activeGamesDirectoryAccess: SettingsStore.ScopedAccess?
    private var pendingCloudProfileID: String?
    var onFullscreenRequest: ((Bool) -> Void)?

    init(
        settings: SettingsStore = SettingsStore(),
        pathResolver: SolEnginePathResolver = SolEnginePathResolver(),
        metadataService: SolEngineMetadataService = SolEngineMetadataService(),
        scannerService: GameScannerService = GameScannerService(),
        embeddedRuntime: SolEngineEmbeddedRuntime? = nil,
        backendService: SolEngineBackendService = SolEngineBackendService(),
        thumbnailService: ThumbnailService = ThumbnailService(),
        solEngineConfiguration: SolEngineConfigurationStore? = nil,
        iCloudProfileSync: ICloudProfileSyncService? = nil,
        appleAccount: AppleAccountService? = nil,
        updateService: GitHubUpdateService? = nil
    ) {
        self.settings = settings
        self.pathResolver = pathResolver
        self.metadataService = metadataService
        self.scannerService = scannerService
        self.embeddedRuntime = embeddedRuntime ?? .shared
        self.backendService = backendService
        self.thumbnailService = thumbnailService
        self.solEngineConfiguration = solEngineConfiguration ?? SolEngineConfigurationStore()
        self.iCloudProfileSync = iCloudProfileSync ?? ICloudProfileSyncService()
        self.appleAccount = appleAccount ?? AppleAccountService()
        self.updateService = updateService ?? GitHubUpdateService()

        settings.$gamesDirectory
            .dropFirst()
            .sink { [weak self] _ in
                self?.validateGamesDirectory()
                self?.scanGamesIfPossible(force: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .solEngineEmbeddedConsoleLine)
            .compactMap { $0.object as? ConsoleLine }
            .sink { [weak self] line in
                self?.consoleLines.append(line)
            }
            .store(in: &cancellables)

        self.iCloudProfileSync.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.appleAccount.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.updateService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.iCloudProfileSync.$selectedProfileID
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] profileID in
                self?.pendingCloudProfileID = profileID
                self?.applyPendingCloudProfileIfNeeded()
            }
            .store(in: &cancellables)

        self.iCloudProfileSync.$multiplayerProfileID
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] profileID in
                self?.appleAccount.adoptCloudMultiplayerProfile(profileID)
            }
            .store(in: &cancellables)

        self.appleAccount.$linkedProfileID
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] profileID in
                guard let self, self.appleAccount.isConnected else { return }
                self.iCloudProfileSync.publishMultiplayerProfile(profileID)
            }
            .store(in: &cancellables)

        self.appleAccount.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self, state == .connected else { return }
                if let cloudProfileID = self.iCloudProfileSync.multiplayerProfileID {
                    self.appleAccount.adoptCloudMultiplayerProfile(cloudProfileID)
                } else if let localProfileID = self.appleAccount.linkedProfileID {
                    self.iCloudProfileSync.publishMultiplayerProfile(localProfileID)
                }
            }
            .store(in: &cancellables)

        validateSolEngine()
        validateGamesDirectory()
        scanGamesIfPossible()
        notificationService.requestAuthorization()
    }

    var canLaunch: Bool {
        canLaunchAnyGame && selectedGame != nil
    }

    var canLaunchAnyGame: Bool {
        solEngineValidation.isValid && gamesValidation.isValid && !isLaunching
    }

    var selectedProfile: SolEngineProfile? {
        backendProfiles.first(where: \.isDefault) ?? backendProfiles.first
    }

    var canScanAmiibo: Bool {
        isLaunching && (session.phase == .running || session.phase == .paused)
    }

    func rescan() {
        scanGamesIfPossible(force: true)
    }

    func launchSelectedGame() {
        guard canLaunch, let game = selectedGame else { return }
        guard retainGamesDirectoryAccess(for: game.fileURL) else {
            appendSystem("Choose the games folder again in Settings to grant Sol access.")
            return
        }
        guard FileManager.default.fileExists(atPath: game.fileURL.path) else {
            appendSystem("Game file not found: \(game.fileURL.lastPathComponent)")
            releaseGamesDirectoryAccess()
            return
        }
        startSolEngine(
            gameURL: game.fileURL,
            displayName: game.title,
            captureGroup: game.titleId ?? game.title
        ) {
            self.sharedStore.markLaunchedFromApp(game: game)
        }
    }

    func launchGame(withId id: String) {
        guard let game = games.first(where: { $0.id == id }) else {
            appendSystem("Game not found for id \(id)")
            return
        }
        selectedGame = game
        if canLaunch {
            launchSelectedGame()
        } else {
            appendSystem("Launch conditions not met. Check paths in Settings.")
        }
    }

    func launchGame(atPath path: String) {
        guard solEngineValidation.isValid else {
            appendSystem("Sol Engine is not configured. Open Settings.")
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            appendSystem("Game file not found at \(fileURL.lastPathComponent)")
            return
        }
        startSolEngine(
            gameURL: fileURL,
            displayName: fileURL.lastPathComponent,
            captureGroup: fileURL.lastPathComponent
        )
    }

    func stopLaunch() {
        guard isLaunching else { return }

        if pendingEmbeddedLaunch != nil, !embeddedRuntime.isRunning {
            appendSystem("Cancelled Sol Engine launch.")
            finishEmbeddedSession(status: nil)
            return
        }

        appendSystem("Stopping Sol Engine...")
        session.phase = .stopping
        embeddedRuntime.stop()
        beginStopWatchdog()
    }

    func pauseEmulation() {
        performSessionCommand("pause") {
            try embeddedRuntime.pause()
        }
    }

    func resumeEmulation() {
        performSessionCommand("resume") {
            try embeddedRuntime.resume()
        }
    }

    func toggleEmulationPause() {
        if session.isPaused {
            resumeEmulation()
        } else {
            pauseEmulation()
        }
    }

    func setEmulationFullscreen(_ fullscreen: Bool) {
        if let onFullscreenRequest {
            // AppKit owns the host window. Keep the request separate from the
            // session snapshot so a rejected or interrupted Space transition
            // cannot leave Sol reporting a fullscreen state it never entered.
            onFullscreenRequest(fullscreen)
        } else {
            performSessionCommand("change fullscreen mode") {
                try embeddedRuntime.setFullscreen(fullscreen)
            }
        }
    }

    func toggleEmulationFullscreen() {
        setEmulationFullscreen(!session.isFullscreen)
    }

    func setEmulationVolume(_ volume: Float) {
        session.volume = min(max(volume, 0), 1)
        performSessionCommand("change volume") {
            try embeddedRuntime.setVolume(volume)
        }
    }

    func setEmulationVSync(_ mode: SolEngineVSyncMode) {
        performSessionCommand("change VSync") {
            try embeddedRuntime.setVSync(mode.title)
        }
    }

    func takeScreenshot() {
        performSessionCommand("take screenshot") {
            try embeddedRuntime.takeScreenshot()
        }
    }

    func showAmiiboPicker() {
        guard canScanAmiibo else { return }
        amiiboStatusMessage = nil
        isAmiiboScanPending = false
        isAmiiboPickerPresented = true
    }

    func scanAmiibo(id: String, useRandomUUID: Bool) {
        guard canScanAmiibo else {
            amiiboStatusMessage = "Wait for the game to finish loading."
            return
        }
        do {
            try embeddedRuntime.scanAmiibo(id: id, useRandomUUID: useRandomUUID)
            isAmiiboScanPending = true
            amiiboStatusMessage = "Waiting for the game…"
        } catch {
            isAmiiboScanPending = false
            amiiboStatusMessage = error.localizedDescription
        }
    }

    func reconcileEmulationState() {
        if isLaunching, pendingEmbeddedLaunch == nil, !embeddedRuntime.isRunning {
            appendSystem("Sol Engine is no longer running.")
            finishEmbeddedSession(status: nil)
        }
        handlePendingLaunchIfNeeded()
    }

    func attachEmbeddedRenderSurface(_ surface: NSView) {
        guard isLaunching else { return }

        if embeddedRuntime.isRunning {
            embeddedRuntime.updateSurfaceSize(for: surface)
            return
        }

        guard !isAttachingEmbeddedSurface,
              let launch = pendingEmbeddedLaunch,
              let dataDirectoryURL = solEnginePaths?.dataDirectoryURL else {
            return
        }

        isAttachingEmbeddedSurface = true

        do {
            try embeddedRuntime.launch(
                surface: surface,
                gameURL: launch.gameURL,
                captureGroup: launch.captureGroup,
                dataDirectoryURL: dataDirectoryURL,
                onSessionEvent: { [weak self] event in
                    self?.handleSessionEvent(event)
                },
                onTermination: { [weak self] status in
                    self?.appendSystem("Sol Engine exited with status \(status)")
                    self?.notificationService.notify(
                        title: "Sol Engine Stopped",
                        body: status == 0 ? "Emulation stopped" : "Exit status \(status)",
                        priority: status == 0 ? .standard : .timeSensitive
                    )
                    self?.finishEmbeddedSession(status: status)
                }
            )
            pendingEmbeddedLaunch = nil
            launch.didLaunch?()

            if solEngineConfiguration.startFullscreen, !session.isFullscreen {
                // In embedded mode the managed core cannot own the host
                // NSWindow. Honor SolEngine's existing launch preference at the
                // native SwiftUI/AppKit boundary once the Metal surface exists.
                setEmulationFullscreen(true)
            }
        } catch {
            appendSystem("Failed to launch embedded Sol Engine: \(error.localizedDescription)")
            finishEmbeddedSession(status: nil)
        }

        isAttachingEmbeddedSurface = false
    }

    func embeddedRenderSurfaceDidResize(_ surface: NSView) {
        embeddedRuntime.updateSurfaceSize(for: surface)
    }

    func hostFullscreenDidChange(_ fullscreen: Bool) {
        if isGamingMode != fullscreen {
            isGamingMode = fullscreen
        }
        if session.isFullscreen != fullscreen {
            session.isFullscreen = fullscreen
        }
        embeddedRuntime.setHostFullscreenState(fullscreen)
    }

    func clearConsole() {
        consoleLines.removeAll()
    }

    func refreshBackendStatus() {
        runBackendOperation(.status)
    }

    func installKeys(from url: URL) {
        runBackendOperation(.installKeys(url))
    }

    func installFirmware(from url: URL) {
        runBackendOperation(.installFirmware(url))
    }

    func importSolEngineData(from sourceURL: URL) {
        guard !isLaunching, !isBackendOperationRunning,
              let destinationURL = solEnginePaths?.dataDirectoryURL else {
            return
        }

        isBackendOperationRunning = true
        backendStatus.errorMessage = nil
        statusMessage = "Importing existing engine data…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await dataMigrationService.importData(
                    from: sourceURL,
                    to: destinationURL
                )
                isBackendOperationRunning = false
                solEngineConfiguration.connect(to: destinationURL)
                refreshBackendStatus()
                refreshPlaytimeMetadata()
                scanGamesIfPossible(force: true)

                let skipped = result.skippedItemCount == 0
                    ? ""
                    : " \(result.skippedItemCount) existing item(s) were kept."
                statusMessage =
                    "Imported \(result.importedItemCount) engine-data item(s)." + skipped
            } catch {
                isBackendOperationRunning = false
                backendStatus.errorMessage = error.localizedDescription
                statusMessage = "Engine data was not imported."
                appendSystem("Sol Engine data import: \(error.localizedDescription)")
            }
        }
    }

    func scanContent() {
        runBackendOperation(.scanContent)
    }

    func refreshBackendInputs() {
        runBackendOperation(.listInputs)
    }

    func assignInputDevice(_ device: SolEngineInputDevice, to player: SolEnginePlayerIndex) {
        runBackendOperation(.setInput(deviceID: device.id, player: player))
    }

    func setControllerBinding(
        _ button: SolEnginePhysicalButton,
        for control: SolEngineLogicalControl,
        player: SolEnginePlayerIndex
    ) {
        runBackendOperation(.setInputBinding(control, button, player: player))
    }

    func resetControllerBindings(for player: SolEnginePlayerIndex) {
        runBackendOperation(.resetInputBindings(player: player))
    }

    func refreshProfiles() {
        runBackendOperation(.listProfiles)
    }

    func selectProfile(_ profile: SolEngineProfile) {
        guard !profile.isDefault else { return }
        pendingCloudProfileID = nil
        runBackendOperation(.setProfile(profile.id))
    }

    func linkAppleAccountToSelectedProfile() {
        guard let selectedProfile else { return }
        appleAccount.linkMultiplayerProfile(selectedProfile.id)
        iCloudProfileSync.publishMultiplayerProfile(selectedProfile.id)
        statusMessage = "\(selectedProfile.name) is now the multiplayer profile"
    }

    func disconnectAppleAccount() {
        appleAccount.disconnect()
        iCloudProfileSync.clearMultiplayerProfile()
        statusMessage = "Apple Account disconnected from Sol"
    }

    func revealSolEngineDataDirectory() {
        guard let url = solEnginePaths?.dataDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealGameFile(_ game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([game.fileURL])
    }

    func revealModsDirectory(for game: Game) {
        revealTitleDirectory(for: game, components: ["mods", "contents"])
    }

    func revealSDCardModsDirectory(for game: Game) {
        revealTitleDirectory(for: game, components: ["sdcard", "atmosphere", "contents"])
    }

    func revealGameDataDirectory(for game: Game) {
        revealTitleDirectory(for: game, components: ["games"])
    }

    func revealScreenshotsDirectory() {
        revealDataSubdirectory(components: ["screenshots"])
    }

    func revealSaveDataDirectory() {
        revealDataSubdirectory(components: ["bis", "user", "save"])
    }

    func clearImageCache() {
        ImageCache.shared.clearAll()
        SharedThumbnailStore.shared.clearAll()
        settings.bumpBackgroundCacheVersion()
        statusMessage = "Image cache cleared"
        if let current = selectedGame {
            selectedGame = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                self.selectedGame = current
            }
        }
    }

    func rebuildBackgrounds() {
        settings.bumpBackgroundCacheVersion()
        statusMessage = "Rebuilding background art…"
        if let current = selectedGame {
            selectedGame = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                self.selectedGame = current
            }
        }
    }

    func selectNextGame() {
        guard !games.isEmpty else { return }
        guard let selected = selectedGame, let index = games.firstIndex(where: { $0.id == selected.id }) else {
            selectedGame = games.first
            return
        }
        let nextIndex = (index + 1) % games.count
        selectedGame = games[nextIndex]
    }

    func selectPreviousGame() {
        guard !games.isEmpty else { return }
        guard let selected = selectedGame, let index = games.firstIndex(where: { $0.id == selected.id }) else {
            selectedGame = games.first
            return
        }
        let prevIndex = (index - 1 + games.count) % games.count
        selectedGame = games[prevIndex]
    }

    private func validateSolEngine() {
        if let resolved = pathResolver.resolveBundledNativeCore() {
            solEngineValidation = .valid(message: "Bundled native Sol Engine core found")
            solEnginePaths = resolved
            solEngineConfiguration.connect(to: resolved.dataDirectoryURL)
            sharedStore.updateValidation(solEngineValid: true, gamesValid: gamesValidation.isValid)
            refreshBackendStatus()
            return
        }

        solEngineValidation = .invalid(message: "Bundled native Sol Engine core is missing")
        solEnginePaths = nil
        solEngineConfiguration.connect(to: nil)
        sharedStore.updateValidation(solEngineValid: false, gamesValid: gamesValidation.isValid)
    }

    private func validateGamesDirectory() {
        guard !settings.gamesDirectory.isEmpty else {
            gamesValidation = .invalid(message: "Select games directory")
            sharedStore.updateValidation(solEngineValid: solEngineValidation.isValid, gamesValid: false)
            return
        }
        guard let access = settings.beginAccessing(.games) else {
            gamesValidation = .invalid(message: "Invalid games directory")
            sharedStore.updateValidation(solEngineValid: solEngineValidation.isValid, gamesValid: false)
            return
        }
        defer { access.stop() }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: access.url.path, isDirectory: &isDir), isDir.boolValue {
            gamesValidation = .valid(message: "Games directory found")
            sharedStore.updateValidation(solEngineValid: solEngineValidation.isValid, gamesValid: true)
        } else {
            gamesValidation = .invalid(message: "Invalid games directory")
            sharedStore.updateValidation(solEngineValid: solEngineValidation.isValid, gamesValid: false)
        }
    }

    private func scanGamesIfPossible(force: Bool = false) {
        if force {
            cancelCurrentScan()
        }
        guard !isLaunching else { return }
        guard gamesValidation.isValid else { return }
        guard !isScanning else { return }

        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        statusMessage = "Scanning games..."

        guard let gamesAccess = settings.beginAccessing(.games) else {
            isScanning = false
            statusMessage = "Invalid games directory"
            return
        }
        let gamesURL = gamesAccess.url
        let dataDir = solEnginePaths?.dataDirectoryURL

        scanTask = Task { [weak self] in
            defer {
                gamesAccess.stop()
            }
            guard let self else { return }

            let metadata = await metadataService.loadMetadata(from: dataDir)
            do {
                try Task.checkCancellation()
                let games = try await scannerService.scanGames(in: gamesURL, metadata: metadata)
                try Task.checkCancellation()
                guard self.scanGeneration == generation else { return }

                self.games = games
                self.sharedStore.updateGamesFromApp(games)
                self.spotlightService.indexGames(games)
                if let selected = self.selectedGame, let refreshed = games.first(where: { $0.id == selected.id }) {
                    self.selectedGame = refreshed
                } else {
                    self.selectedGame = games.first
                }
                self.finishScan(generation: generation)
                self.statusMessage = games.isEmpty ? "No games found" : "Found \(games.count) games"
                self.handlePendingLaunchIfNeeded()
            } catch is CancellationError {
                self.finishScan(generation: generation)
            } catch {
                guard self.scanGeneration == generation else { return }
                self.games = []
                self.finishScan(generation: generation)
                self.statusMessage = "Scan failed: \(error.localizedDescription)"
            }
        }
    }

    private func cancelCurrentScan() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func finishScan(generation: Int) {
        guard scanGeneration == generation else { return }
        scanTask = nil
        isScanning = false
    }

    private func startSolEngine(
        gameURL: URL,
        displayName: String,
        captureGroup: String?,
        didLaunch: (() -> Void)? = nil
    ) {
        guard !isLaunching else {
            appendSystem("Sol Engine is already running")
            return
        }

        // A CAMetalLayer is a presentation-session object. Reusing one after
        // MoltenVK has destroyed its swapchain can leave already-presented
        // drawables attached to the next launch, so every session owns a fresh
        // render view and layer pair.
        embeddedRenderView = SolEngineRenderView()
        isLaunching = true
        isLaunchIsolationActive = true
        dlsmProviderStatus = DLSMProviderStatus(stage: "discovering")
        session = SolEngineSessionSnapshot(phase: .launching)
        launchActivity = SolEngineLaunchActivity()
        embeddedLaunchID = UUID()
        pendingEmbeddedLaunch = PendingEmbeddedLaunch(
            gameURL: gameURL,
            displayName: displayName,
            captureGroup: captureGroup,
            didLaunch: didLaunch
        )
        SoundPlayer.shared.play(.launch)
        appendSystem("Launching \(displayName)...")
        notificationService.notify(title: "Launching Sol", body: displayName)

        // The SwiftUI hierarchy now transitions to EmbeddedGamePlayerView.
        // Its AppKit view starts the managed engine once it has a real window
        // and a stable Cocoa view pointer.
    }

    private func handleSessionEvent(_ event: SolEngineNativeEvent) {
        guard event.protocolVersion == 1 else {
            appendSystem("Unsupported native Sol Engine protocol v\(event.protocolVersion)")
            return
        }

        if let capabilities = event.capabilities {
            session.capabilities = Set(capabilities)
        }
        if let phase = event.phase.flatMap(SolEngineSessionPhase.init(rawValue:)) {
            session.phase = phase
        }
        if let fullscreen = event.fullscreen {
            session.isFullscreen = fullscreen
        }
        if let volume = event.volume {
            session.volume = volume
        }
        if let title = event.title {
            session.title = title
        }
        if let titleID = event.titleID {
            session.titleID = titleID
        }

        switch event.event {
        case "host.ready":
            appendSystem("Embedded Sol Engine engine connected")
            launchActivity.update(
                stage: "starting-engine",
                message: "Starting Sol Engine"
            )
            try? embeddedRuntime.queryState()
        case "launch.progress":
            launchActivity.update(
                stage: event.loadStage ?? "loading",
                message: event.message ?? "Loading game",
                current: event.progressCurrent,
                total: event.progressTotal
            )
        case "launch.first-frame":
            launchActivity.markFirstFramePresented()
            appendSystem(event.message ?? "First Metal frame presented")
        case "amiibo.scanned":
            isAmiiboScanPending = false
            amiiboStatusMessage = event.message ?? "Amiibo scanned"
            isAmiiboPickerPresented = false
        case "fullscreen.requested":
            if let fullscreen = event.fullscreen {
                onFullscreenRequest?(fullscreen)
            }
        case "screenshot.saved":
            if let path = event.path {
                statusMessage = "Screenshot saved: \(URL(fileURLWithPath: path).lastPathComponent)"
                appendSystem("Screenshot saved to \(path)")
            }
        case "dialog.request":
            presentNativeDialog(event)
        case "dlsm.attachment-labels":
            appendSystem(event.message ?? "DLSM attachment labels were unavailable")
        case "dlsm.provider-readiness":
            dlsmProviderStatus.merge(event)
            if event.sceneCut == true || event.depthReady == true || event.motionReady == true {
                appendSystem(event.message ?? "DLSM provider readiness changed")
            }
        case "playtime.updated":
            refreshPlaytimeMetadata(preferredTitleID: event.titleID)
        case "host.error":
            appendSystem(event.message ?? "Native Sol Engine error")
            if event.command == "scan-amiibo" {
                isAmiiboScanPending = false
                amiiboStatusMessage = event.message ?? "The Amiibo could not be scanned."
            }
        default:
            break
        }
    }

    private func performSessionCommand(_ name: String, action: () throws -> Void) {
        do {
            try action()
        } catch {
            appendSystem("Could not \(name): \(error.localizedDescription)")
        }
    }

    private func presentNativeDialog(_ event: SolEngineNativeEvent) {
        guard let requestID = event.requestID, !requestID.isEmpty else {
            appendSystem("Sol Engine requested a native dialog without a request ID.")
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        let kind = event.dialogKind ?? "message"
        let buttonTitles = event.buttons?.filter { !$0.isEmpty } ?? []
        let buttons = buttonTitles.isEmpty
            ? (kind == "confirmation" ? ["Continue", "Cancel"] : ["OK"])
            : buttonTitles
        var proposedValue = event.defaultValue ?? ""
        var validationMessage: String?

        while true {
            let alert = NSAlert()
            alert.messageText = event.title?.nilIfBlank ?? "Sol"
            alert.informativeText = [event.message?.nilIfBlank, validationMessage]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            alert.alertStyle = kind == "confirmation" ? .warning : .informational
            buttons.forEach { alert.addButton(withTitle: $0) }

            var textField: NSTextField?
            var choiceControl: NSPopUpButton?
            if kind == "text" {
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
                field.stringValue = proposedValue
                field.placeholderString = "Enter text"
                field.lineBreakMode = .byTruncatingTail
                alert.accessoryView = field
                textField = field
            } else if kind == "choice", let options = event.options, !options.isEmpty {
                let control = NSPopUpButton(
                    frame: NSRect(x: 0, y: 0, width: 360, height: 28),
                    pullsDown: false
                )
                control.addItems(withTitles: options.map(\.label))
                if let defaultValue = event.defaultValue,
                   let defaultIndex = options.firstIndex(where: { $0.value == defaultValue }) {
                    control.selectItem(at: defaultIndex)
                }
                alert.accessoryView = control
                choiceControl = control
            }

            alert.layout()
            if let textField {
                alert.window.initialFirstResponder = textField
                textField.selectText(nil)
            }

            let response = alert.runModal()
            let accepted = response == .alertFirstButtonReturn
            let value: String? = {
                if let textField {
                    return textField.stringValue
                }
                if let choiceControl,
                   let options = event.options,
                   options.indices.contains(choiceControl.indexOfSelectedItem) {
                    return options[choiceControl.indexOfSelectedItem].value
                }
                return nil
            }()

            if accepted, kind == "text", let value {
                proposedValue = value
                let minimum = max(event.minimumLength ?? 0, 0)
                let maximum = event.maximumLength

                if value.count < minimum {
                    validationMessage = "Enter at least \(minimum) characters."
                    NSSound.beep()
                    continue
                }
                if let maximum, value.count > maximum {
                    validationMessage = "Enter no more than \(maximum) characters."
                    NSSound.beep()
                    continue
                }
                if let inputMessage = nativeInputValidationMessage(
                    for: value,
                    mode: event.inputMode
                ) {
                    validationMessage = inputMessage
                    NSSound.beep()
                    continue
                }
            }

            do {
                try embeddedRuntime.respondToDialog(
                    requestID: requestID,
                    accepted: accepted,
                    value: value
                )
            } catch {
                appendSystem("Could not answer Sol Engine dialog: \(error.localizedDescription)")
            }
            return
        }
    }

    private func nativeInputValidationMessage(for value: String, mode: String?) -> String? {
        switch mode?.lowercased() {
        case "numeric":
            let allowed = CharacterSet(charactersIn: "0123456789.")
            return value.unicodeScalars.allSatisfy(allowed.contains)
                ? nil
                : "Use numbers and decimal points only."
        case "ascii":
            return value.unicodeScalars.allSatisfy(\.isASCII)
                ? nil
                : "Use ASCII characters only."
        default:
            return nil
        }
    }

    private func finishEmbeddedSession(status: Int32?) {
        stopWatchdogTask?.cancel()
        stopWatchdogTask = nil
        pendingEmbeddedLaunch = nil
        isAmiiboPickerPresented = false
        isAmiiboScanPending = false
        amiiboStatusMessage = nil
        embeddedRenderView.retireAfterSession()
        embeddedLaunchID = nil
        isAttachingEmbeddedSurface = false
        isLaunching = false
        isLaunchIsolationActive = false
        session = SolEngineSessionSnapshot()
        launchActivity = SolEngineLaunchActivity()
        releaseGamesDirectoryAccess()
        refreshPlaytimeMetadata()
        if isGamingMode {
            onFullscreenRequest?(false)
        }
    }

    private func retainGamesDirectoryAccess(for gameURL: URL) -> Bool {
        releaseGamesDirectoryAccess()
        guard let access = settings.beginAccessing(.games) else { return false }

        let rootPath = access.url.standardizedFileURL.path
        let gamePath = gameURL.standardizedFileURL.path
        guard gamePath == rootPath || gamePath.hasPrefix(rootPath + "/") else {
            access.stop()
            return false
        }

        activeGamesDirectoryAccess = access
        return true
    }

    private func releaseGamesDirectoryAccess() {
        activeGamesDirectoryAccess?.stop()
        activeGamesDirectoryAccess = nil
    }

    private func refreshPlaytimeMetadata(preferredTitleID: String? = nil) {
        guard let dataDirectoryURL = solEnginePaths?.dataDirectoryURL else { return }

        playtimeRefreshTask?.cancel()
        playtimeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let metadata = await metadataService.loadMetadata(from: dataDirectoryURL)
            guard !Task.isCancelled, !metadata.isEmpty else { return }

            let preferredKey = preferredTitleID?.uppercased()
            var didChange = false
            let refreshedGames = games.map { game in
                guard let titleID = game.titleId?.uppercased(),
                      preferredKey == nil || preferredKey == titleID,
                      let entry = metadata[titleID],
                      entry.hoursPlayed != game.hoursPlayed ||
                      entry.lastPlayed != game.lastPlayed else {
                    return game
                }

                didChange = true
                return Game(
                    id: game.id,
                    title: entry.title.isEmpty ? game.title : entry.title,
                    titleId: game.titleId,
                    fileURL: game.fileURL,
                    hoursPlayed: entry.hoursPlayed,
                    lastPlayed: entry.lastPlayed
                )
            }

            guard didChange else { return }
            games = refreshedGames
            if let selectedID = selectedGame?.id {
                selectedGame = refreshedGames.first(where: { $0.id == selectedID })
            }
            sharedStore.updateGamesFromApp(refreshedGames)
            spotlightService.indexGames(refreshedGames)
        }
    }

    private func beginStopWatchdog() {
        stopWatchdogTask?.cancel()
        let launchID = embeddedLaunchID
        stopWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            guard let self,
                  self.embeddedLaunchID == launchID,
                  self.isLaunching else {
                return
            }

            self.appendSystem("Sol Engine is still stopping; retrying the shutdown request.")
            self.embeddedRuntime.stop()

            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }

            guard self.embeddedLaunchID == launchID, self.isLaunching else {
                return
            }
            self.statusMessage = "Sol Engine is taking longer than expected to stop."
        }
    }

    private struct PendingEmbeddedLaunch {
        let gameURL: URL
        let displayName: String
        let captureGroup: String?
        let didLaunch: (() -> Void)?
    }

    private func runBackendOperation(_ operation: SolEngineBackendOperation) {
        guard !isLaunching else {
            backendStatus.errorMessage = "Stop emulation before changing system files."
            return
        }
        guard !isBackendOperationRunning else {
            return
        }
        guard let executableURL = solEnginePaths?.executableURL,
              let dataDirectoryURL = solEnginePaths?.dataDirectoryURL else {
            let message =
                "This Sol build is missing its bundled engine. Build the Sol scheme again before changing system files or content."
            backendStatus.errorMessage = message
            appendSystem(message)
            return
        }

        isBackendOperationRunning = true
        backendStatus.errorMessage = nil

        Task { [weak self] in
            guard let self else { return }

            do {
                let events = try await backendService.run(
                    executableURL: executableURL,
                    dataDirectoryURL: dataDirectoryURL,
                    operation: operation
                )
                applyBackendEvents(events)

                if operation.requiresAuthoritativeStatusRefresh {
                    do {
                        let statusEvents = try await backendService.run(
                            executableURL: executableURL,
                            dataDirectoryURL: dataDirectoryURL,
                            operation: .status
                        )
                        applyBackendEvents(statusEvents)
                    } catch {
                        backendStatus.errorMessage =
                            "The change completed, but Sol could not refresh its status: \(error.localizedDescription)"
                    }
                }
            } catch {
                if operation.requiresAuthoritativeStatusRefresh,
                   let statusEvents = try? await backendService.run(
                       executableURL: executableURL,
                       dataDirectoryURL: dataDirectoryURL,
                       operation: .status
                   ) {
                    applyBackendEvents(statusEvents)
                }
                backendStatus.errorMessage = error.localizedDescription
                appendSystem("Sol Engine backend: \(error.localizedDescription)")
            }

            isBackendOperationRunning = false
            applyPendingCloudProfileIfNeeded()
        }
    }

    private func applyBackendEvents(_ events: [SolEngineNativeEvent]) {
        if events.contains(where: { $0.operation == "list-inputs" }) {
            backendControllerMappings.removeAll()
        }

        for event in events where event.event == "input.mapping" {
            guard let inputID = event.inputID,
                  let inputName = event.inputName,
                  let rawPlayer = event.playerIndex,
                  let player = SolEnginePlayerIndex(rawValue: rawPlayer),
                  let rawBindings = event.bindings else {
                continue
            }

            let bindingPairs: [(SolEngineLogicalControl, SolEnginePhysicalButton)] =
                rawBindings.compactMap { rawControl, rawButton in
                    guard let control = SolEngineLogicalControl(rawValue: rawControl),
                          let button = SolEnginePhysicalButton.fromEngineName(rawButton) else {
                        return nil
                    }
                    return (control, button)
                }
            let bindings = Dictionary(uniqueKeysWithValues: bindingPairs)
            backendControllerMappings[player] = SolEngineControllerMapping(
                inputID: inputID,
                inputName: inputName,
                player: player,
                bindings: bindings
            )
        }

        let profileEvents = events.filter { $0.event == "profile.item" }
        if !profileEvents.isEmpty {
            backendProfiles = profileEvents.compactMap { event -> SolEngineProfile? in
                guard let id = event.profileID,
                      let name = event.profileName else {
                    return nil
                }

                return SolEngineProfile(
                    id: id,
                    name: name,
                    imageData: event.profileImageBase64.flatMap {
                        Data(base64Encoded: $0)
                    },
                    isDefault: event.isDefault ?? false
                )
            }
        }

        if events.contains(where: { $0.operation == "list-inputs" }) {
            backendInputDevices = events
                .compactMap { event -> SolEngineInputDevice? in
                    guard event.event == "input.device",
                          let id = event.inputID,
                          let name = event.inputName,
                          let rawKind = event.inputKind,
                          let kind = SolEngineInputDevice.Kind(rawValue: rawKind) else {
                        return nil
                    }

                    return SolEngineInputDevice(
                        id: id,
                        name: name,
                        kind: kind,
                        usesEastConfirmButton: event.usesEastConfirmButton ?? false,
                        isConnected: event.isConnected ?? true,
                        assignedPlayers: (event.assignedPlayers ?? []).compactMap(
                            SolEnginePlayerIndex.init(rawValue:)
                        )
                    )
                }
                .sorted {
                    if $0.kind != $1.kind {
                        return $0.kind == .controller
                    }
                    if $0.assignedPlayers.isEmpty != $1.assignedPlayers.isEmpty {
                        return !$0.assignedPlayers.isEmpty
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
        }

        if let assignmentEvent = events.first(where: {
            $0.event == "backend.operation" &&
            $0.operation == "set-input" &&
            $0.success == true
        }),
           let inputID = assignmentEvent.inputID,
           let rawPlayer = assignmentEvent.playerIndex,
           let player = SolEnginePlayerIndex(rawValue: rawPlayer) {
            backendInputDevices = backendInputDevices.map { device in
                var players = device.assignedPlayers.filter { $0 != player }
                if device.id == inputID {
                    players.append(player)
                }
                return SolEngineInputDevice(
                    id: device.id,
                    name: device.name,
                    kind: device.kind,
                    usesEastConfirmButton: device.usesEastConfirmButton,
                    isConnected: device.isConnected,
                    assignedPlayers: players
                )
            }
        }

        for event in events {
            if event.event == "backend.status" {
                if let hasProdKeys = event.hasProdKeys {
                    backendStatus.hasProdKeys = hasProdKeys
                }
                backendStatus.firmwareVersion = event.firmwareVersion
                backendStatus.dataDirectory = event.dataDirectory
                backendStatus.dlcCount = event.dlcCount ?? backendStatus.dlcCount
                backendStatus.updateCount = event.updateCount ?? backendStatus.updateCount
                backendStatus.contentDirectoryCount =
                    event.directoryCount ?? backendStatus.contentDirectoryCount
            }

            if event.event == "backend.operation", let message = event.message {
                backendStatus.message = message
                backendStatus.dlcCount = event.dlcCount ?? backendStatus.dlcCount
                backendStatus.updateCount = event.updateCount ?? backendStatus.updateCount
                backendStatus.contentDirectoryCount =
                    event.directoryCount ?? backendStatus.contentDirectoryCount
                appendSystem(message)
            }
        }

        if let profileEvent = events.first(where: {
            $0.event == "backend.operation" &&
            $0.operation == "set-profile" &&
            $0.success == true
        }), let profileID = profileEvent.profileID,
           let profile = backendProfiles.first(where: { $0.id == profileID }) {
            backendProfiles = backendProfiles.map { existing in
                SolEngineProfile(
                    id: existing.id,
                    name: existing.name,
                    imageData: existing.imageData,
                    isDefault: existing.id == profileID
                )
            }
            iCloudProfileSync.publishSelectedProfile(profile.id)
            if appleAccount.isConnected {
                appleAccount.linkMultiplayerProfile(profile.id)
                iCloudProfileSync.publishMultiplayerProfile(profile.id)
            }
            statusMessage = "Switched to \(profile.name)"
        }

        solEngineConfiguration.reload()
    }

    private func applyPendingCloudProfileIfNeeded() {
        guard !isBackendOperationRunning,
              !isLaunching,
              let profileID = pendingCloudProfileID,
              let profile = backendProfiles.first(where: { $0.id == profileID }) else {
            return
        }

        if profile.isDefault {
            pendingCloudProfileID = nil
            return
        }

        pendingCloudProfileID = nil
        runBackendOperation(.setProfile(profileID))
    }

    private func revealTitleDirectory(for game: Game, components: [String]) {
        guard let titleID = game.titleId?.lowercased(),
              titleID.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil else {
            statusMessage = "This title has no valid title ID yet."
            return
        }
        revealDataSubdirectory(components: components + [titleID])
    }

    private func revealDataSubdirectory(components: [String]) {
        guard var url = solEnginePaths?.dataDirectoryURL else { return }
        for component in components {
            url.appendPathComponent(component, isDirectory: true)
        }

        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            statusMessage = "Could not open folder: \(error.localizedDescription)"
        }
    }

    private func appendSystem(_ message: String) {
        consoleLines.append(ConsoleLine(timestamp: Date(), text: message + "\n", stream: .system))
    }

    func handlePendingLaunchIfNeeded() {
        guard !games.isEmpty, !isPendingLaunchCheckInFlight else { return }
        isPendingLaunchCheckInFlight = true
        sharedStore.consumePendingLaunch { [weak self] pendingId, pendingPath in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPendingLaunchCheckInFlight = false
                self.handlePendingLaunch(id: pendingId, path: pendingPath)
            }
        }
    }

    private func handlePendingLaunch(id pendingId: String?, path pendingPath: String?) {
        if let pendingId, let game = games.first(where: { $0.id == pendingId }) {
            selectedGame = game
            if canLaunch {
                launchSelectedGame()
            } else {
                appendSystem("Pending launch blocked. Check Settings.")
            }
            return
        }
        if let pendingPath {
            if let game = games.first(where: { $0.fileURL.path == pendingPath }) {
                selectedGame = game
                if canLaunch {
                    launchSelectedGame()
                } else {
                    appendSystem("Pending launch blocked. Check Settings.")
                }
                return
            }
            launchGame(atPath: pendingPath)
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "sol" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let host = url.host ?? ""
        let query = components.queryItems ?? []

        if host == "open" {
            isSettingsPresented = query.first(where: { $0.name == "settings" })?.value == "1"
            return
        }

        if host == "launch" {
            if let id = query.first(where: { $0.name == "id" })?.value {
                launchGame(withId: id)
                return
            }
            if let path = query.first(where: { $0.name == "path" })?.value?.removingPercentEncoding {
                launchGame(atPath: path)
            }
        }
    }
}

struct ValidationResult {
    let isValid: Bool
    let message: String

    static func valid(message: String) -> ValidationResult {
        ValidationResult(isValid: true, message: message)
    }

    static func invalid(message: String) -> ValidationResult {
        ValidationResult(isValid: false, message: message)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
