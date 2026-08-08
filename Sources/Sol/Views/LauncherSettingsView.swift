import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers

struct LauncherSettingsView: View {
    private enum SettingsTab: Hashable {
        case general
        case library
        case content
        case system
        case emulation
        case multiplayer
        case graphics
        case audio
        case controllers
        case console
    }

    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var controllerViewModel: ControllerManagerViewModel
    @ObservedObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: SettingsTab = .general

    init(viewModel: LauncherViewModel, controllerViewModel: ControllerManagerViewModel) {
        self.viewModel = viewModel
        self.controllerViewModel = controllerViewModel
        self.settings = viewModel.settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalPane
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            libraryPane
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
                .tag(SettingsTab.library)

            contentPane
                .tabItem {
                    Label("Content", systemImage: "shippingbox")
                }
                .tag(SettingsTab.content)

            nativeSystemPane
                .tabItem {
                    Label("System", systemImage: "internaldrive")
                }
                .tag(SettingsTab.system)

            SolEngineEmulationSettingsPane(configuration: viewModel.solEngineConfiguration)
                .tabItem {
                    Label("Emulation", systemImage: "cpu")
                }
                .tag(SettingsTab.emulation)

            SolEngineMultiplayerSettingsPane(
                viewModel: viewModel,
                configuration: viewModel.solEngineConfiguration
            )
                .tabItem {
                    Label("Multiplayer", systemImage: "person.2")
                }
                .tag(SettingsTab.multiplayer)

            SolEngineGraphicsSettingsPane(
                configuration: viewModel.solEngineConfiguration,
                settings: settings,
                providerStatus: viewModel.dlsmProviderStatus
            )
                .tabItem {
                    Label("Graphics", systemImage: "display")
                }
                .tag(SettingsTab.graphics)

            SolEngineAudioSettingsPane(configuration: viewModel.solEngineConfiguration)
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2")
                }
                .tag(SettingsTab.audio)

            ControllerManagerView(
                viewModel: controllerViewModel,
                launcherViewModel: viewModel
            )
                .tabItem {
                    Label("Controllers", systemImage: "gamecontroller")
                }
                .tag(SettingsTab.controllers)

            diagnosticsPane
                .tabItem {
                    Label("Console", systemImage: "terminal")
                }
                .tag(SettingsTab.console)
        }
        .frame(width: 900, height: 680)
        .scenePadding()
    }

    private var generalPane: some View {
        Form {
            Section("Locations") {
                LabeledContent("Sol Engine") {
                    Label("Bundled native runtime", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }

                DirectoryPickerView(
                    title: "Games",
                    path: $settings.gamesDirectory,
                    validation: viewModel.gamesValidation,
                    onPickURL: { settings.storeBookmark(for: .games, url: $0) }
                )
            }

            Section("Engine") {
                LabeledContent("Core bridge") {
                    if let status = SolEngineNativeBridge.detectedStatus {
                        Label(
                            "Native ABI v\(status.protocolVersion)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else {
                        Text("Native process bridge")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Frontend") {
                    Label("SwiftUI + AppKit only", systemImage: "apple.logo")
                }

                Text("Sol Engine has no Avalonia packages or views. Every Sol surface, setting, and live emulation control is native macOS UI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Profile and iCloud") {
                LabeledContent("Apple Account") {
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
                                    linkingProfileID: viewModel.selectedProfile?.id,
                                    profileName: viewModel.selectedProfile?.name
                                )
                            }
                        )
                        .signInWithAppleButtonStyle(
                            colorScheme == .dark ? .whiteOutline : .black
                        )
                        .frame(width: 210, height: 32)
                    }
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

                LabeledContent("Default profile") {
                    if viewModel.backendProfiles.isEmpty {
                        Button("Load Profiles") {
                            viewModel.refreshProfiles()
                        }
                        .disabled(viewModel.isBackendOperationRunning)
                    } else {
                        HStack(spacing: 8) {
                            ProfileAvatarView(
                                profile: viewModel.selectedProfile,
                                generatedAvatarURL: viewModel.appleAccount.avatarURL,
                                size: 28
                            )

                            Picker(
                                "Default profile",
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
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 164)
                        }
                        .disabled(
                            viewModel.isBackendOperationRunning ||
                            viewModel.isLaunching
                        )
                    }
                }

                LabeledContent("iCloud") {
                    if viewModel.iCloudProfileSync.availability == .available {
                        Label(
                            viewModel.iCloudProfileSync.availability.title,
                            systemImage: viewModel.iCloudProfileSync.availability.systemImage
                        )
                        .foregroundStyle(.green)
                    } else {
                        Label(
                            viewModel.iCloudProfileSync.availability.title,
                            systemImage: viewModel.iCloudProfileSync.availability.systemImage
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                Text("Sign in with Apple links the active Sol profile to your multiplayer identity. Sol syncs that profile link through iCloud; games, keys, firmware, room codes, and save data stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle(
                    "Open Sol at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )

                Text("Sol opens automatically after you sign in to your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var libraryPane: some View {
        Form {
            Section("Library") {
                LabeledContent("Games found") {
                    Text(viewModel.games.count, format: .number)
                        .monospacedDigit()
                }

                if let status = viewModel.statusMessage {
                    LabeledContent("Status") {
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        if viewModel.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button(viewModel.isScanning ? "Scanning…" : "Rescan Now") {
                            viewModel.rescan()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isScanning)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refresh library")
                        Text("Scan the games folder for new or removed titles.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Artwork") {
                settingsActionRow(
                    title: "Rebuild backgrounds",
                    detail: "Fetch fresh wide artwork for every game.",
                    buttonTitle: "Rebuild"
                ) {
                    viewModel.rebuildBackgrounds()
                }

                settingsActionRow(
                    title: "Image cache",
                    detail: "Remove downloaded covers and backgrounds.",
                    buttonTitle: "Clear Cache",
                    role: .destructive
                ) {
                    viewModel.clearImageCache()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var nativeSystemPane: some View {
        Form {
            Section("System Files") {
                LabeledContent("Production keys") {
                    Label(
                        viewModel.backendStatus.hasProdKeys ? "Installed" : "Not Found",
                        systemImage: viewModel.backendStatus.hasProdKeys
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(viewModel.backendStatus.hasProdKeys ? .green : .orange)
                }

                LabeledContent {
                    Button("Install Keys…", action: chooseKeys)
                        .disabled(systemActionsDisabled)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keys")
                        Text("Validates the selected .keys file in the Sol Engine backend before installing it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Firmware") {
                    if let version = viewModel.backendStatus.firmwareVersion {
                        Label(version, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Installed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                LabeledContent {
                    Menu("Install Firmware…") {
                        Button("Choose ZIP or XCI…", action: chooseFirmwarePackage)
                        Button("Choose Extracted Folder…", action: chooseFirmwareDirectory)
                    }
                        .disabled(systemActionsDisabled)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Firmware package")
                        Text("Accepts a firmware ZIP, XCI, or extracted firmware folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Native Backend") {
                LabeledContent("Data directory") {
                    Text(viewModel.backendStatus.dataDirectory ?? "Not available")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Reveal in Finder") {
                        viewModel.revealSolEngineDataDirectory()
                    }
                    .disabled(viewModel.backendStatus.dataDirectory == nil)

                    Button("Refresh Status") {
                        viewModel.refreshBackendStatus()
                    }
                    .disabled(systemActionsDisabled)

                    Button("Import Existing Data…", action: chooseExistingEngineData)
                        .disabled(systemActionsDisabled)

                    if viewModel.isBackendOperationRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack {
                    Button("Screenshots") {
                        viewModel.revealScreenshotsDirectory()
                    }

                    Button("Save Data") {
                        viewModel.revealSaveDataDirectory()
                    }
                }

                Text("Sol uses its own Application Support folder. Import copies keys, firmware, profiles, saves, and other compatible engine data only after you choose an existing folder; current Sol files are never replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let message = viewModel.backendStatus.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var contentPane: some View {
        Form {
            Section("DLC and Title Updates") {
                if viewModel.solEngineConfiguration.autoloadDirectories.isEmpty {
                    LabeledContent {
                        Button("Add Folder…", action: chooseContentDirectory)
                            .disabled(systemActionsDisabled)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No content folders")
                            Text("Add a folder containing update or DLC NSP files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

                    Button("Add Another Folder…", action: chooseContentDirectory)
                        .disabled(systemActionsDisabled)
                }

                Text("Sol searches these folders recursively for NSP content, registers DLC with the matching title, and automatically selects the newest discovered update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Registered Content") {
                LabeledContent("Downloadable content") {
                    Text(viewModel.backendStatus.dlcCount, format: .number)
                        .monospacedDigit()
                }

                LabeledContent("Title updates") {
                    Text(viewModel.backendStatus.updateCount, format: .number)
                        .monospacedDigit()
                }

                LabeledContent("Folders scanned") {
                    Text(viewModel.backendStatus.contentDirectoryCount, format: .number)
                        .monospacedDigit()
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        if viewModel.isBackendOperationRunning {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button(
                            viewModel.isBackendOperationRunning ? "Scanning…" : "Scan Now"
                        ) {
                            viewModel.scanContent()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            systemActionsDisabled ||
                            viewModel.solEngineConfiguration.autoloadDirectories.isEmpty
                        )
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refresh DLC and updates")
                        Text("Writes Sol compatible content metadata used by the native core.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = viewModel.backendStatus.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private func settingsActionRow(
        title: String,
        detail: String,
        buttonTitle: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent {
            Button(buttonTitle, role: role, action: action)
                .disabled(viewModel.isScanning)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
            message: "The native backend will validate the selected keys and replace any matching installed key files."
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
        panel.title = "Choose DLC and Update Folder"
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
        panel.title = "Choose Existing Engine Data"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirm(
            title: "Import Existing Engine Data?",
            message: "Sol will copy compatible data into its own Application Support folder. Existing Sol files will be kept.",
            primaryButton: "Import"
        ) else { return }
        viewModel.importSolEngineData(from: url)
    }

    private func removeContentDirectory(_ directory: String) {
        viewModel.solEngineConfiguration.autoloadDirectories.removeAll { $0 == directory }
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
