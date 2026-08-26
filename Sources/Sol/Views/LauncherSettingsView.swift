import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers

struct LauncherSettingsView: View {
    private enum SettingsDestination: String, Hashable, Identifiable {
        case general
        case library
        case account
        case system
        case emulation
        case multiplayer
        case graphics
        case audio
        case controllers
        case developer
        case console

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .library: "Games & Content"
            case .account: "Profile & Cloud"
            case .system: "System Files"
            case .emulation: "Performance"
            case .multiplayer: "Multiplayer"
            case .graphics: "Graphics"
            case .audio: "Audio"
            case .controllers: "Controls"
            case .developer: "Developer"
            case .console: "Console"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .library: "folder"
            case .account: "person.crop.square"
            case .system: "internaldrive"
            case .emulation: "cpu"
            case .multiplayer: "person.2"
            case .graphics: "display"
            case .audio: "speaker.wave.2"
            case .controllers: "gamecontroller"
            case .developer: "hammer"
            case .console: "terminal"
            }
        }

        var detail: String {
            switch self {
            case .general: "Startup and setup preferences."
            case .library: "Games, patches, DLC, and artwork."
            case .account: "Your Sol name, picture, Apple Account, and cloud data."
            case .system: "Keys, firmware, screenshots, and save data."
            case .emulation: "CPU, memory, launch behavior, and core accuracy."
            case .multiplayer: "Identity, rooms, networking, and online privacy."
            case .graphics: "Rendering, image quality, and experimental DLSM options."
            case .audio: "Output backend, volume, and audio behavior."
            case .controllers: "Keyboard, controller assignments, and button mappings."
            case .developer: "Diagnostics and low-level Sol Engine options."
            case .console: "Runtime messages from Sol and the native engine."
            }
        }
    }

    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var controllerViewModel: ControllerManagerViewModel
    @ObservedObject var friendsStore: SolFriendsStore
    @ObservedObject var onboardingStore: SolOnboardingStore
    @ObservedObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedDestination: SettingsDestination? = .general
    @State private var isEditingProfile = false
    @State private var isManagingGameUsers = false
    @State private var migratedLegacyGameUserID: String?

    init(
        viewModel: LauncherViewModel,
        controllerViewModel: ControllerManagerViewModel,
        friendsStore: SolFriendsStore,
        onboardingStore: SolOnboardingStore
    ) {
        self.viewModel = viewModel
        self.controllerViewModel = controllerViewModel
        self.friendsStore = friendsStore
        self.onboardingStore = onboardingStore
        self.settings = viewModel.settings
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            settingsSidebar
        } detail: {
            settingsDetail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: 900,
            idealWidth: 1_020,
            minHeight: 640,
            idealHeight: 720
        )
        .toolbar(removing: .title)
        .containerBackground(.thickMaterial, for: .window)
        .sheet(isPresented: $isEditingProfile) {
            ProfileEditorSheet(
                viewModel: viewModel,
                friendsStore: friendsStore
            )
        }
        .sheet(isPresented: $isManagingGameUsers) {
            ProfileGameUsersView(viewModel: viewModel)
                .frame(width: 780, height: 620)
        }
        .onAppear(perform: prepareIdentity)
        .onChange(of: viewModel.selectedProfile?.id) { _, _ in
            prepareIdentity()
        }
    }

    private var settingsSidebar: some View {
        List(selection: $selectedDestination) {
            Section {
                settingsRow(.general)
                settingsRow(.library)
            }

            Section("Account & Online") {
                settingsRow(.account)
                settingsRow(.multiplayer)
            }

            Section("System") {
                settingsRow(.system)
            }

            Section("Emulation") {
                settingsRow(.emulation)
                settingsRow(.graphics)
                settingsRow(.audio)
            }

            Section("Input") {
                settingsRow(.controllers)
            }

            Section("Advanced") {
                settingsRow(.developer)
                settingsRow(.console)
            }
        }
        .listStyle(.sidebar)
        .toolbar(removing: .sidebarToggle)
        .navigationTitle("Settings")
        .navigationSplitViewColumnWidth(min: 196, ideal: 218, max: 238)
    }

    private func settingsRow(_ destination: SettingsDestination) -> some View {
        Label(destination.title, systemImage: destination.systemImage)
            .tag(destination)
    }

    private var settingsDetail: some View {
        let destination = selectedDestination ?? .general

        return VStack(spacing: 0) {
            settingsHeader(for: destination)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)

            destinationView(destination)
                .scrollContentBackground(.hidden)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        }
        .navigationTitle(destination.title)
    }

    private func settingsHeader(for destination: SettingsDestination) -> some View {
        settingsHeaderContent(for: destination)
    }

    private func settingsHeaderContent(
        for destination: SettingsDestination
    ) -> some View {
        HStack(spacing: 12) {
            sidebarVisibilityButton

            Divider()
                .frame(height: 24)

            Image(systemName: destination.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(
                        cornerRadius: SolGeometry.controlCornerRadius,
                        style: .continuous
                    )
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(destination.title)
                    .font(.title3.weight(.semibold))
                Text(destination.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsHeaderSurface())
    }

    private var sidebarVisibilityButton: some View {
        let title = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = isSidebarVisible ? .detailOnly : .all
            }
        } label: {
            Label(title, systemImage: "sidebar.left")
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .help(title)
        .accessibilityLabel(title)
    }

    private var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    @ViewBuilder
    private func destinationView(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .general:
            generalPane
        case .library:
            libraryPane
        case .account:
            accountPane
        case .system:
            nativeSystemPane
        case .emulation:
            SolEngineEmulationSettingsPane(configuration: viewModel.solEngineConfiguration)
        case .multiplayer:
            SolEngineMultiplayerSettingsPane(
                viewModel: viewModel,
                configuration: viewModel.solEngineConfiguration,
                friendsStore: friendsStore
            )
        case .graphics:
            SolEngineGraphicsSettingsPane(
                configuration: viewModel.solEngineConfiguration,
                settings: settings,
                providerStatus: viewModel.dlsmProviderStatus
            )
        case .audio:
            SolEngineAudioSettingsPane(configuration: viewModel.solEngineConfiguration)
        case .controllers:
            ControllerManagerView(
                viewModel: controllerViewModel,
                launcherViewModel: viewModel
            )
        case .developer:
            SolEngineDeveloperSettingsPane(configuration: viewModel.solEngineConfiguration)
        case .console:
            diagnosticsPane
        }
    }

    private var generalPane: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Open Sol at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )
            }

            Section("Setup") {
                LabeledContent {
                    Button("Run Setup Again…") {
                        onboardingStore.reset()
                        NSApp.keyWindow?.close()
                    }
                    .disabled(viewModel.isLaunching)
                } label: {
                    Text("Setup assistant")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var accountPane: some View {
        Form {
            Section("Sol Profile") {
                LabeledContent("Identity") {
                    HStack(spacing: 12) {
                        ProfileAvatarView(
                            profile: viewModel.selectedProfile,
                            generatedAvatarURL: viewModel.appleAccount.avatarURL,
                            socialIdentity: friendsStore.identity,
                            size: 38
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(friendsStore.identity.displayName)
                                .font(.headline)
                            Text(friendsStore.identity.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Button("Edit Name & Picture…") {
                            isEditingProfile = true
                        }
                    }
                }

                Text("This is your name and picture across Home, Profile, Friends, multiplayer, and Sol Cloud. You can change it whenever you like.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Game User") {
                LabeledContent("Active game user") {
                    if viewModel.backendProfiles.isEmpty {
                        Button("Load Game Users") {
                            viewModel.refreshProfiles()
                        }
                        .disabled(viewModel.isBackendOperationRunning)
                    } else {
                        Picker(
                            "Active game user",
                            selection: Binding(
                                get: { viewModel.selectedProfile?.id ?? "" },
                                set: { profileID in
                                    guard let profile = viewModel.backendProfiles.first(
                                        where: { $0.id == profileID }
                                    ) else {
                                        return
                                    }
                                    viewModel.selectProfile(profile)
                                }
                            )
                        ) {
                            ForEach(viewModel.backendProfiles) { profile in
                                Text(displayedGameUserName(profile)).tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        .disabled(
                            viewModel.isBackendOperationRunning ||
                            viewModel.isLaunching
                        )
                    }
                }

                LabeledContent {
                    Button("Manage Game Users…") {
                        isManagingGameUsers = true
                    }
                    .disabled(viewModel.isLaunching)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Users and save ownership")
                        Text("Create, rename, choose a picture, or change the default user games see.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Sol mirrors your Sol Profile name and picture to the active game user, while keeping each user’s saves separate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Services") {
                LabeledContent("Apple Account") {
                    appleAccountControl
                }

                if let accountError = viewModel.appleAccount.errorMessage {
                    Label(
                        accountError,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if viewModel.appleAccount.state == .requiresSignedBuild {
                    Label(
                        "A provisioned Apple development or distribution build enables both Sign in with Apple and iCloud.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                LabeledContent("iCloud") {
                    Label(
                        viewModel.iCloudProfileSync.availability.title,
                        systemImage: viewModel.iCloudProfileSync.availability.systemImage
                    )
                    .foregroundStyle(
                        viewModel.iCloudProfileSync.availability == .available
                            ? Color.green
                            : Color.secondary
                    )
                }
            }

            Section("Cloud Data") {
                Text("When Sol Cloud is enabled, iCloud backs up profiles, saves, screenshots, play activity, portable settings, and local restore points.")
                Text("Games, keys, firmware, room codes, and device paths stay on this Mac.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var appleAccountControl: some View {
        if viewModel.appleAccount.isConnected {
            HStack(spacing: 8) {
                Label(
                    viewModel.appleAccount.displayName
                        ?? "Connected with Apple",
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                .foregroundStyle(.green)

                Button("Disconnect") {
                    viewModel.disconnectAppleAccount()
                }
            }
        } else if viewModel.appleAccount.state == .requiresSignedBuild {
            Label(
                viewModel.appleAccount.state.title,
                systemImage: viewModel.appleAccount.state.systemImage
            )
            .foregroundStyle(.secondary)
        } else {
            SignInWithAppleButton(
                .signIn,
                onRequest: viewModel.appleAccount.prepareAuthorizationRequest,
                onCompletion: { result in
                    viewModel.appleAccount.completeAuthorization(
                        result,
                        linkingProfileID: friendsStore.identity.localProfileID.uuidString,
                        profileName: friendsStore.identity.displayName
                    )
                }
            )
            .signInWithAppleButtonStyle(
                colorScheme == .dark ? .whiteOutline : .black
            )
            .frame(width: 210, height: 32)
        }
    }

    private var libraryPane: some View {
        Form {
            Section("Games") {
                DirectoryPickerView(
                    title: "Game folder",
                    path: $settings.gamesDirectory,
                    validation: viewModel.gamesValidation,
                    onPickURL: { settings.storeBookmark(for: .games, url: $0) }
                )

                LabeledContent("Library") {
                    HStack(spacing: 8) {
                        if viewModel.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button(viewModel.isScanning ? "Scanning…" : "Rescan") {
                            viewModel.rescan()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isScanning)
                    }
                }
            }

            Section("Patches & DLC") {
                if viewModel.solEngineConfiguration.autoloadDirectories.isEmpty {
                    LabeledContent("Content folders") {
                        Button("Choose Folder…", action: chooseContentDirectory)
                            .disabled(systemActionsDisabled)
                    }
                } else {
                    ForEach(
                        viewModel.solEngineConfiguration.autoloadDirectories,
                        id: \.self
                    ) { directory in
                        LabeledContent {
                            Button(role: .destructive) {
                                removeContentDirectory(directory)
                            } label: {
                                Label("Remove", systemImage: "minus")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(systemActionsDisabled)
                            .help("Stop scanning this folder")
                        } label: {
                            Label {
                                Text(directory)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                    }

                    LabeledContent("Folders") {
                        Button("Add Folder…", action: chooseContentDirectory)
                            .disabled(systemActionsDisabled)
                    }
                }

                LabeledContent("Patches and DLC") {
                    HStack(spacing: 8) {
                        if viewModel.isBackendOperationRunning {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button(
                            viewModel.isBackendOperationRunning ? "Scanning…" : "Rescan"
                        ) {
                            viewModel.scanContent()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            systemActionsDisabled ||
                            viewModel.solEngineConfiguration.autoloadDirectories.isEmpty
                        )
                    }
                }
            }

            Section("Artwork") {
                LabeledContent("Game backgrounds") {
                    Button("Rebuild", action: viewModel.rebuildBackgrounds)
                        .disabled(viewModel.isScanning)
                }

                LabeledContent("Downloaded artwork") {
                    Button("Clear Cache", role: .destructive, action: viewModel.clearImageCache)
                        .disabled(viewModel.isScanning)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var nativeSystemPane: some View {
        Form {
            Section("Keys & Firmware") {
                LabeledContent("Production keys") {
                    HStack(spacing: 10) {
                        Label(
                            viewModel.backendStatus.hasProdKeys ? "Installed" : "Not Found",
                            systemImage: viewModel.backendStatus.hasProdKeys
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(viewModel.backendStatus.hasProdKeys ? .green : .orange)

                        Button("Install…", action: chooseKeys)
                            .disabled(systemActionsDisabled)
                    }
                }

                LabeledContent("Firmware") {
                    HStack(spacing: 10) {
                        if let version = viewModel.backendStatus.firmwareVersion {
                            Label(version, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Not Installed", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }

                        Menu("Install…") {
                            Button("Choose ZIP or XCI…", action: chooseFirmwarePackage)
                            Button("Choose Extracted Folder…", action: chooseFirmwareDirectory)
                        }
                        .disabled(systemActionsDisabled)
                    }
                }
            }

            Section("Data") {
                LabeledContent("Open") {
                    HStack(spacing: 8) {
                        Button("Screenshots", action: viewModel.revealScreenshotsDirectory)
                        Button("Save Data", action: viewModel.revealSaveDataDirectory)
                    }
                }

                LabeledContent("Existing data") {
                    Button("Import…", action: chooseExistingEngineData)
                        .disabled(systemActionsDisabled)
                }

                if let error = viewModel.backendStatus.errorMessage {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var diagnosticsPane: some View {
        ConsoleView(lines: viewModel.consoleLines) {
            viewModel.clearConsole()
        }
        .padding(.top, 8)
    }

    private func displayedGameUserName(_ profile: SolEngineProfile) -> String {
        isLegacyGameUserName(profile.name)
            ? friendsStore.identity.displayName
            : profile.name
    }

    private func prepareIdentity() {
        friendsStore.prepareIdentity(
            defaultDisplayName: viewModel.appleAccount.displayName ?? "Sol Player"
        )

        guard let profile = viewModel.selectedProfile,
              isLegacyGameUserName(profile.name),
              migratedLegacyGameUserID != profile.id else {
            return
        }

        migratedLegacyGameUserID = profile.id
        viewModel.synchronizeSolIdentityToSelectedProfile(
            displayName: friendsStore.identity.displayName,
            image: nil
        )
    }

    private func isLegacyGameUserName(_ name: String) -> Bool {
        name.compare(
            "RyuPlayer",
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    private var systemActionsDisabled: Bool {
        viewModel.isBackendOperationRunning || viewModel.isLaunching
    }

    private func chooseKeys() {
        let panel = NSOpenPanel()
        panel.title = "Choose Sol Keys"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "keys") ?? .data,
        ]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirm(
            title: "Install Sol Keys?",
            message: "Sol will validate the selected keys and replace any matching installed key files."
        ) else { return }
        viewModel.installKeys(from: url)
    }

    private func chooseFirmwarePackage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Firmware Package"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .zip,
            UTType(filenameExtension: "xci") ?? .data,
        ]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirm(
            title: "Install Firmware?",
            message: "Sol will verify this package, then replace the currently registered firmware with the selected version."
        ) else { return }
        viewModel.installFirmware(from: url)
    }

    private func chooseFirmwareDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Extracted Firmware Folder"
        panel.message = "Choose the folder that directly contains the extracted .nca firmware files."
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirm(
            title: "Install Firmware From This Folder?",
            message: "Sol will verify the extracted firmware before replacing the currently registered version."
        ) else { return }
        viewModel.installFirmware(from: url)
    }

    private func chooseContentDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Patches and DLC Folder"
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        viewModel.solEngineConfiguration.autoloadDirectories += panel.urls.map(\.path)
        viewModel.scanContent()
    }

    private func chooseExistingEngineData() {
        let panel = NSOpenPanel()
        panel.title = "Choose Existing Sol Data"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirm(
            title: "Import Existing Sol Data?",
            message: "Sol will copy compatible data into its own Application Support folder. Existing Sol files will be kept.",
            primaryButton: "Import"
        ) else { return }
        viewModel.importSolEngineData(from: url)
    }

    private func removeContentDirectory(_ directory: String) {
        viewModel.solEngineConfiguration.autoloadDirectories.removeAll { $0 == directory }
        viewModel.scanContent()
    }

    private func confirm(
        title: String,
        message: String,
        primaryButton: String = "Install"
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: primaryButton)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct SettingsHeaderSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(
                    cornerRadius: SolGeometry.panelCornerRadius,
                    style: .continuous
                )
            )
        } else {
            content.background(
                .regularMaterial,
                in: RoundedRectangle(
                    cornerRadius: SolGeometry.panelCornerRadius,
                    style: .continuous
                )
            )
        }
    }
}
