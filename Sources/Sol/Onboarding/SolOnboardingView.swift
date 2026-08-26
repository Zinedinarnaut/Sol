import AppKit
import AuthenticationServices
import ColorfulX
import DockProgress
import Glur
import Shimmer
import SwiftUI
import UniformTypeIdentifiers

struct SolOnboardingView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var store: SolOnboardingStore
    @ObservedObject var friendsStore: SolFriendsStore
    @ObservedObject private var configuration: SolEngineConfigurationStore
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var cloudSync: SolCloudSyncService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hasAppeared = false
    @State private var identityDisplayName: String
    @State private var identityAvatarSource: SolProfileAvatarSource
    @State private var identityPixelAvatar: SolPixelAvatar
    @State private var identityCustomAvatarRevision: UUID?
    @State private var identityCustomAvatarDraftData: Data?
    @State private var identityNameWasEdited = false
    @State private var isChoosingIdentityImage = false
    @State private var isPreparingIdentityImage = false
    @State private var identityErrorMessage: String?

    init(
        viewModel: LauncherViewModel,
        store: SolOnboardingStore,
        friendsStore: SolFriendsStore
    ) {
        self.viewModel = viewModel
        self.store = store
        self.friendsStore = friendsStore
        self.configuration = viewModel.solEngineConfiguration
        self.settings = viewModel.settings
        self.cloudSync = viewModel.cloudSync
        _identityDisplayName = State(
            initialValue: SolOnboardingIdentityPolicy.initialDisplayName(
                friendsStore.identity.displayName
            )
        )
        _identityAvatarSource = State(
            initialValue: friendsStore.identity.avatarSource ?? .pixel
        )
        _identityPixelAvatar = State(
            initialValue: friendsStore.identity.resolvedPixelAvatar
        )
        _identityCustomAvatarRevision = State(
            initialValue: friendsStore.identity.customAvatarRevision
        )
        _identityCustomAvatarDraftData = State(initialValue: nil)
    }

    var body: some View {
        ZStack {
            SolOnboardingBackground(reduceMotion: reduceMotion)

            HStack(spacing: 0) {
                sidebar
                detail
            }
            .frame(maxWidth: 1_120, maxHeight: 760)
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.82),
                in: RoundedRectangle(
                    cornerRadius: SolGeometry.panelCornerRadius,
                    style: .continuous
                )
            )
            .modifier(SolOnboardingWindowSurface())
            .padding(28)
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.975)
        }
        .frame(minWidth: 940, minHeight: 650)
        .dockProgress(store.isCompleted ? nil : store.progress, style: .bar)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) {
                hasAppeared = true
            }
            viewModel.refreshBackendStatus()
            viewModel.refreshProfiles()
            applyAppleIdentityDefaultsIfAppropriate()
        }
        .onChange(of: store.currentStep) { _, step in
            guard step == .essentials || step == .account else { return }
            if step == .essentials {
                viewModel.refreshBackendStatus()
            } else if viewModel.backendProfiles.isEmpty {
                viewModel.refreshProfiles()
            }
        }
        .onChange(of: viewModel.appleAccount.state) { _, state in
            guard state == .connected else { return }
            if viewModel.selectedProfile != nil {
                viewModel.linkAppleAccountToSelectedProfile()
            }
            applyAppleIdentityDefaultsIfAppropriate()
        }
        .fileImporter(
            isPresented: $isChoosingIdentityImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleIdentityImageImport
        )
        .alert("Profile Couldn’t Be Saved", isPresented: identityErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(identityErrorMessage ?? "Try again.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Set Up Sol")
                        .font(.headline)
                    Text("First run")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 20)

            VStack(spacing: 4) {
                ForEach(Array(SolOnboardingStore.Step.allCases.enumerated()), id: \.element.id) { index, step in
                    Button {
                        changeStep(to: step)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: sidebarSymbol(for: step, at: index))
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.title)
                                    .font(.callout.weight(.medium))
                                Text(step.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(step == store.currentStep ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .background(
                            step == store.currentStep
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canSelect(step))
                    .opacity(store.canSelect(step) ? 1 : 0.48)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: store.progress)
                    .progressViewStyle(.linear)
                Text("Step \(currentStepNumber) of \(SolOnboardingStore.Step.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(width: 250)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup steps")
    }

    private var detail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    stepHeader
                    stepContent
                        .id(store.currentStep)
                        .transition(stepTransition)
                }
                .padding(.horizontal, 46)
                .padding(.top, 42)
                .padding(.bottom, 34)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
            footer
        }
        .clipped()
    }

    private var stepHeader: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: store.currentStep.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                Text(store.currentStep.title)
                    .font(.system(size: 30, weight: .semibold))
                Text(headerDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch store.currentStep {
        case .welcome:
            welcomeStep
        case .account:
            accountStep
        case .iCloud:
            cloudStep
        case .essentials:
            essentialsStep
        case .library:
            libraryStep
        case .performance:
            performanceStep
        case .ready:
            readyStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Sol will check the parts needed for a stable first launch, while keeping your games and system files under your control.")
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                setupFeature(
                    "Native from the first screen",
                    detail: "The setup assistant uses macOS controls, sheets, accessibility, and reduced-motion preferences.",
                    symbol: "macwindow"
                )
                Divider().padding(.leading, 52)
                setupFeature(
                    "Private by design",
                    detail: "Apple account identifiers stay in Keychain. Games, keys, firmware, and local paths are never uploaded.",
                    symbol: "lock.shield"
                )
                Divider().padding(.leading, 52)
                setupFeature(
                    "Ready before launch",
                    detail: "Sol verifies its engine, required system files, and game-library permission before opening Home.",
                    symbol: "checkmark.seal"
                )
            }
            .modifier(SolOnboardingPanelSurface())

            Label(
                "Use only system files and game backups obtained from hardware and software you own.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            identitySetupPanel

            Text("Apple Account (optional)")
                .font(.headline)

            if viewModel.appleAccount.isConnected {
                HStack(spacing: 15) {
                    AsyncImage(url: viewModel.appleAccount.avatarURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 58, height: 58)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewModel.appleAccount.displayName ?? "Apple Account")
                            .font(.title3.weight(.semibold))
                        if let email = viewModel.appleAccount.email {
                            Text(email)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Label("Connected securely", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Use for Sol") {
                            applyAppleIdentity(force: true)
                        }

                        Button("Disconnect") {
                            viewModel.disconnectAppleAccount()
                            if identityAvatarSource == .apple {
                                identityAvatarSource = .pixel
                            }
                        }
                    }
                }
                .padding(18)
                .modifier(SolOnboardingPanelSurface())

                if viewModel.appleAccount.isPrivateRelay {
                    Label(
                        "Apple is protecting your real email address with Private Relay.",
                        systemImage: "envelope.badge.shield.half.filled"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

            } else if viewModel.appleAccount.state == .requiresSignedBuild {
                setupNotice(
                    title: "A signed Sol build is required",
                    detail: "Run the provisioned Sol scheme from Xcode, or use a signed release build, to enable Sign in with Apple.",
                    symbol: "signature",
                    color: .orange
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Use your Apple Account for a stable Sol identity, multiplayer profile, and private cloud namespace. Apple only shares your name and email the first time you approve access.")
                        .fixedSize(horizontal: false, vertical: true)

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
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(width: 238, height: 38)
                }
                .padding(18)
                .modifier(SolOnboardingPanelSurface())
            }

            if viewModel.appleAccount.state == .checking {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Checking your Apple account…")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = viewModel.appleAccount.errorMessage {
                setupNotice(
                    title: "Apple Account could not connect",
                    detail: error,
                    symbol: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }

            Text("Your Sol username and picture work without an Apple Account. Signing in adds a private account namespace for multiplayer and iCloud restore.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var identitySetupPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ProfileAvatarView(
                    profile: viewModel.selectedProfile,
                    generatedAvatarURL: viewModel.appleAccount.avatarURL,
                    socialIdentity: identityPreview,
                    customAvatarOverride: identityCustomAvatarDraftImage,
                    size: 76
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text("Your Sol identity")
                        .font(.headline)

                    TextField("Username", text: $identityDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onChange(of: identityDisplayName) { _, _ in
                            identityNameWasEdited = true
                        }

                    Text("This name appears everywhere in Sol and is mirrored to the active game user.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Picker("Profile picture", selection: $identityAvatarSource) {
                ForEach(availableIdentityAvatarSources) { source in
                    Label(source.title, systemImage: source.systemImage)
                        .tag(source)
                }
            }
            .pickerStyle(.segmented)

            switch identityAvatarSource {
            case .pixel:
                SolPixelAvatarPicker(selection: $identityPixelAvatar)
            case .custom:
                identityCustomImageControls
            case .apple:
                Label(
                    "Sol will use the stable avatar associated with this Apple connection.",
                    systemImage: "apple.logo"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case .gameProfile:
                Label(
                    "Sol will use the picture stored with your active game user.",
                    systemImage: "person.crop.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Label(
                "The same profile record powers Home, Profile, Friends, multiplayer, and iCloud backup.",
                systemImage: "arrow.triangle.2.circlepath.icloud"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .modifier(SolOnboardingPanelSurface())
    }

    private var cloudStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: viewModel.iCloudProfileSync.availability.systemImage)
                    .font(.title2)
                    .foregroundStyle(iCloudStatusColor)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.iCloudProfileSync.availability.title)
                        .font(.headline)
                    Text(iCloudStatusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(18)
            .modifier(SolOnboardingPanelSurface())

            Toggle(
                "Back up Sol data automatically",
                isOn: $cloudSync.automaticSyncEnabled
            )
            .toggleStyle(.switch)
            .disabled(!viewModel.appleAccount.isConnected || viewModel.iCloudProfileSync.availability != .available)

            VStack(spacing: 0) {
                setupFeature(
                    "Included",
                    detail: "Profiles, saves, screenshots, play activity, portable preferences, and encrypted account-safe metadata.",
                    symbol: "icloud.and.arrow.up"
                )
                Divider().padding(.leading, 52)
                setupFeature(
                    "Stays on this Mac",
                    detail: "Games, keys, firmware, room passphrases, and absolute device or content paths.",
                    symbol: "internaldrive"
                )
            }
            .modifier(SolOnboardingPanelSurface())

            Label(
                "Sign in with Apple identifies your Sol profile. Your Mac’s iCloud account provides storage; they are checked separately.",
                systemImage: "person.2.badge.gearshape"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var essentialsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupStatusRow(
                title: "Sol Engine",
                detail: viewModel.solEngineValidation.message,
                isReady: viewModel.solEngineValidation.isValid,
                actionTitle: nil,
                action: nil
            )

            setupStatusRow(
                title: "Production keys",
                detail: viewModel.backendStatus.hasProdKeys
                    ? "Installed and recognized by Sol Engine"
                    : "Choose a .keys file or a folder containing your dumped keys.",
                isReady: viewModel.backendStatus.hasProdKeys,
                actionTitle: viewModel.backendStatus.hasProdKeys ? "Replace…" : "Install…",
                action: chooseKeys
            )

            setupStatusRow(
                title: "Firmware",
                detail: viewModel.backendStatus.firmwareVersion.map { "Version \($0) is installed" }
                    ?? "Choose a firmware ZIP, XCI, or extracted NCA folder.",
                isReady: viewModel.backendStatus.firmwareVersion != nil,
                actionTitle: viewModel.backendStatus.firmwareVersion == nil ? "Install…" : "Replace…",
                action: chooseFirmware
            )

            if viewModel.isBackendOperationRunning {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Sol Engine is validating your selection…")
                        .foregroundStyle(.secondary)
                        .shimmering(active: !reduceMotion)
                }
            }

            if let error = viewModel.backendStatus.errorMessage {
                setupNotice(
                    title: "System files need attention",
                    detail: error,
                    symbol: "exclamationmark.octagon.fill",
                    color: .red
                )
            }

            Label(
                "Sol validates these locally and copies them into its private Application Support directory. They are never part of an iCloud backup.",
                systemImage: "lock.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var libraryStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                DirectoryPickerView(
                    title: "Games folder",
                    path: $settings.gamesDirectory,
                    validation: viewModel.gamesValidation,
                    onPickURL: { settings.storeBookmark(for: .games, url: $0) }
                )

                if viewModel.isScanning {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Scanning your library…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .shimmering(active: !reduceMotion)
                    }
                } else if viewModel.gamesValidation.isValid {
                    Label(
                        "\(viewModel.games.count) game\(viewModel.games.count == 1 ? "" : "s") found",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                }
            }
            .padding(18)
            .modifier(SolOnboardingPanelSurface())

            Label(
                "Sol stores a security-scoped bookmark so App Sandbox builds can reopen only the folder you chose.",
                systemImage: "hand.raised.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Game images and local file paths stay on this Mac and are excluded from Sol Cloud.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var performanceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("These are conservative defaults for Apple Silicon. Every option remains available in Settings after setup.")
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                setupToggle(
                    "Start games full screen",
                    detail: "Use the display’s full available resolution without a windowed bezel.",
                    isOn: Binding(
                        get: { configuration.startFullscreen },
                        set: { configuration.startFullscreen = $0 }
                    )
                )
                Divider().padding(.leading, 52)
                setupToggle(
                    "Docked mode",
                    detail: "Prefer the game’s docked presentation and resolution profile.",
                    isOn: Binding(
                        get: { configuration.dockedMode },
                        set: { configuration.dockedMode = $0 }
                    )
                )
                Divider().padding(.leading, 52)
                setupToggle(
                    "Apple hypervisor acceleration",
                    detail: "Use hardware virtualization where the Sol Engine core supports it.",
                    isOn: Binding(
                        get: { configuration.useHypervisor },
                        set: { configuration.useHypervisor = $0 }
                    )
                )
                Divider().padding(.leading, 52)
                setupToggle(
                    "Shader cache and PTC",
                    detail: "Reduce repeated shader and CPU translation work across launches.",
                    isOn: Binding(
                        get: { configuration.enableShaderCache && configuration.enablePTC },
                        set: {
                            configuration.enableShaderCache = $0
                            configuration.enablePTC = $0
                        }
                    )
                )
            }
            .modifier(SolOnboardingPanelSurface())

            Label(
                "DLSM remains disabled in public builds while its temporal path is experimental.",
                systemImage: "testtube.2"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sol is ready when every required item below is green. Optional Apple services can be connected at any time from your profile.")
                .font(.title3)

            VStack(spacing: 0) {
                readinessRow("Native Sol Engine", ready: viewModel.solEngineValidation.isValid)
                Divider().padding(.leading, 48)
                readinessRow("Production keys", ready: viewModel.backendStatus.hasProdKeys)
                Divider().padding(.leading, 48)
                readinessRow(
                    viewModel.backendStatus.firmwareVersion.map { "Firmware \($0)" } ?? "Firmware",
                    ready: viewModel.backendStatus.firmwareVersion != nil
                )
                Divider().padding(.leading, 48)
                readinessRow("Game library access", ready: viewModel.gamesValidation.isValid)
                Divider().padding(.leading, 48)
                readinessRow("Apple Account", ready: viewModel.appleAccount.isConnected, optional: true)
                Divider().padding(.leading, 48)
                readinessRow("iCloud", ready: viewModel.iCloudProfileSync.availability == .available, optional: true)
            }
            .modifier(SolOnboardingPanelSurface())

            if requiredSetupIsReady {
                setupNotice(
                    title: "Everything required is ready",
                    detail: "Enter Sol to scan the library and choose a game.",
                    symbol: "checkmark.seal.fill",
                    color: .green
                )
            } else {
                setupNotice(
                    title: "Finish the required items",
                    detail: "Go back to System Files or Game Library and complete the items marked in orange.",
                    symbol: "arrow.uturn.backward.circle.fill",
                    color: .orange
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Back") {
                changeStep(backward: true)
            }
            .disabled(!store.canGoBack)

            Spacer()

            if let continueHint {
                Text(continueHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(continueButtonTitle) {
                continueSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue || viewModel.isBackendOperationRunning)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
        .background(.bar)
    }

    private var headerDetail: String {
        switch store.currentStep {
        case .welcome:
            return "A short guided setup before your first game."
        case .account:
            return "Choose the one name and picture Sol uses across every profile surface."
        case .iCloud:
            return "Review exactly what Sol can back up across your Macs."
        case .essentials:
            return "Install the system files Sol Engine needs to start compatible software."
        case .library:
            return "Grant access to the one folder that contains your local game backups."
        case .performance:
            return "Choose stable Apple Silicon and full-screen defaults."
        case .ready:
            return "One final check before opening your library."
        }
    }

    private var currentStepNumber: Int {
        (SolOnboardingStore.Step.allCases.firstIndex(of: store.currentStep) ?? 0) + 1
    }

    private var requiredSetupIsReady: Bool {
        viewModel.solEngineValidation.isValid &&
            viewModel.backendStatus.hasProdKeys &&
            viewModel.backendStatus.firmwareVersion != nil &&
            viewModel.gamesValidation.isValid
    }

    private var canContinue: Bool {
        switch store.currentStep {
        case .account:
            return !trimmedIdentityDisplayName.isEmpty &&
                !isPreparingIdentityImage &&
                (identityAvatarSource != .custom || hasIdentityCustomImage)
        case .essentials:
            return viewModel.solEngineValidation.isValid &&
                viewModel.backendStatus.hasProdKeys &&
                viewModel.backendStatus.firmwareVersion != nil
        case .library:
            return viewModel.gamesValidation.isValid
        case .ready:
            return requiredSetupIsReady
        default:
            return true
        }
    }

    private var continueButtonTitle: String {
        store.currentStep == .ready ? "Enter Sol" : "Continue"
    }

    private var continueHint: String? {
        guard !canContinue else { return nil }
        switch store.currentStep {
        case .account: return "Choose a username and profile picture"
        case .essentials: return "Keys and firmware are required"
        case .library: return "Choose a valid games folder"
        case .ready: return "Required setup is incomplete"
        default: return nil
        }
    }

    private var iCloudStatusColor: Color {
        viewModel.iCloudProfileSync.availability == .available ? .green : .secondary
    }

    private var trimmedIdentityDisplayName: String {
        identityDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var identityPreview: SolSocialIdentity {
        var identity = friendsStore.identity
        identity.displayName = trimmedIdentityDisplayName
        identity.avatarSource = identityAvatarSource
        identity.pixelAvatar = identityPixelAvatar
        identity.customAvatarRevision = identityCustomAvatarRevision
        return identity
    }

    private var availableIdentityAvatarSources: [SolProfileAvatarSource] {
        var sources: [SolProfileAvatarSource] = [.pixel, .custom]
        if viewModel.appleAccount.isConnected {
            sources.append(.apple)
        }
        if viewModel.selectedProfile != nil {
            sources.append(.gameProfile)
        }
        if !sources.contains(identityAvatarSource) {
            sources.append(identityAvatarSource)
        }
        return sources
    }

    private var identityCustomAvatarDraftImage: NSImage? {
        identityCustomAvatarDraftData.flatMap(NSImage.init(data:))
    }

    private var hasIdentityCustomImage: Bool {
        if identityCustomAvatarDraftData != nil {
            return true
        }
        guard let revision = identityCustomAvatarRevision else { return false }
        return SolProfileImageStore.shared.containsImage(
            profileID: friendsStore.identity.localProfileID,
            revision: revision
        )
    }

    private var identityCustomImageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(hasIdentityCustomImage ? "Replace Image…" : "Choose Image…") {
                    isChoosingIdentityImage = true
                }
                .disabled(isPreparingIdentityImage)

                if isPreparingIdentityImage {
                    ProgressView().controlSize(.small)
                    Text("Preparing image…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if hasIdentityCustomImage {
                    Button("Remove", role: .destructive) {
                        identityCustomAvatarDraftData = nil
                        identityCustomAvatarRevision = nil
                        identityAvatarSource = .pixel
                    }
                    .disabled(isPreparingIdentityImage)
                }
            }

            Label(
                "Sol center-crops the image, removes its metadata, and stores a private normalized copy.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var identityErrorBinding: Binding<Bool> {
        Binding(
            get: { identityErrorMessage != nil },
            set: { if !$0 { identityErrorMessage = nil } }
        )
    }

    private var iCloudStatusDetail: String {
        switch viewModel.iCloudProfileSync.availability {
        case .available:
            return viewModel.appleAccount.isConnected
                ? "This Mac can use Sol’s private iCloud container."
                : "iCloud is available; connect an Apple Account to namespace Sol backups."
        case .signedOut:
            return "Sign in to iCloud in System Settings, then return to Sol."
        case .requiresSignedBuild:
            return "iCloud requires a provisioned development or distribution build."
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private func sidebarSymbol(for step: SolOnboardingStore.Step, at index: Int) -> String {
        if index < currentStepNumber - 1 || (step == .ready && store.isCompleted) {
            return "checkmark.circle.fill"
        }
        return step.systemImage
    }

    private func continueSetup() {
        if store.currentStep == .ready {
            guard requiredSetupIsReady else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                store.complete()
            }
            return
        }
        changeStep(forward: true)
    }

    private func changeStep(
        to step: SolOnboardingStore.Step? = nil,
        forward: Bool = false,
        backward: Bool = false
    ) {
        let destination: SolOnboardingStore.Step? = {
            if let step { return step }
            guard let index = SolOnboardingStore.Step.allCases.firstIndex(
                of: store.currentStep
            ) else { return nil }
            if forward,
               SolOnboardingStore.Step.allCases.indices.contains(index + 1) {
                return SolOnboardingStore.Step.allCases[index + 1]
            }
            if backward, index > 0 {
                return SolOnboardingStore.Step.allCases[index - 1]
            }
            return nil
        }()

        if store.currentStep == .account,
           destination != .account,
           !persistIdentity() {
            return
        }

        withAnimation(reduceMotion ? nil : .snappy(duration: 0.38, extraBounce: 0.04)) {
            if let step {
                store.select(step)
            } else if forward {
                store.advance()
            } else if backward {
                store.goBack()
            }
        }
    }

    @discardableResult
    private func persistIdentity() -> Bool {
        guard canContinue else { return false }

        let profileID = friendsStore.identity.localProfileID
        let originalRevision = friendsStore.identity.customAvatarRevision
        var savedRevision = identityCustomAvatarRevision
        var stagedRevision: UUID?

        do {
            if let identityCustomAvatarDraftData {
                let revision = try SolProfileImageStore.shared.savePreparedImage(
                    identityCustomAvatarDraftData,
                    profileID: profileID
                )
                savedRevision = revision
                stagedRevision = revision
            }

            try friendsStore.updateIdentity(
                displayName: trimmedIdentityDisplayName,
                statusMessage: friendsStore.identity.statusMessage,
                allowsFriendRequests: friendsStore.identity.allowsFriendRequests,
                sharesPlayActivity: friendsStore.identity.sharesPlayActivity,
                appearsInRecentPlayers: friendsStore.identity.appearsInRecentPlayers,
                avatarSource: identityAvatarSource,
                pixelAvatar: identityPixelAvatar,
                customAvatarRevision: savedRevision
            )

            let profileImage = identityImageForGameProfile(
                customRevision: savedRevision
            )
            viewModel.synchronizeSolIdentityToSelectedProfile(
                displayName: trimmedIdentityDisplayName,
                image: profileImage,
                remoteImageURL: identityAvatarSource == .apple
                    ? viewModel.appleAccount.avatarURL
                    : nil
            )

            if let originalRevision,
               originalRevision != savedRevision {
                try? SolProfileImageStore.shared.removeImage(
                    profileID: profileID,
                    revision: originalRevision
                )
            }

            identityCustomAvatarRevision = savedRevision
            identityCustomAvatarDraftData = nil
            identityErrorMessage = nil
            return true
        } catch {
            if let stagedRevision {
                try? SolProfileImageStore.shared.removeImage(
                    profileID: profileID,
                    revision: stagedRevision
                )
            }
            identityErrorMessage = error.localizedDescription
            return false
        }
    }

    private func identityImageForGameProfile(
        customRevision: UUID?
    ) -> NSImage? {
        switch identityAvatarSource {
        case .pixel:
            return SolPixelAvatarRenderer.shared.image(
                for: identityPixelAvatar,
                dimension: 256
            )
        case .custom:
            if let identityCustomAvatarDraftImage {
                return identityCustomAvatarDraftImage
            }
            guard let customRevision else { return nil }
            return SolProfileImageStore.shared.image(
                profileID: friendsStore.identity.localProfileID,
                revision: customRevision
            )
        case .apple:
            return nil
        case .gameProfile:
            return viewModel.selectedProfile?.imageData.flatMap(NSImage.init(data:))
        }
    }

    private func applyAppleIdentityDefaultsIfAppropriate() {
        guard viewModel.appleAccount.isConnected,
              !identityNameWasEdited,
              trimmedIdentityDisplayName.isEmpty ||
                trimmedIdentityDisplayName == "Sol Player" ||
                trimmedIdentityDisplayName == "RyuPlayer" else {
            return
        }
        applyAppleIdentity(force: false)
    }

    private func applyAppleIdentity(force: Bool) {
        guard viewModel.appleAccount.isConnected else { return }
        if let name = viewModel.appleAccount.displayName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !name.isEmpty, name != "Apple Account",
           force || !identityNameWasEdited {
            identityDisplayName = name
        }
        identityAvatarSource = .apple
    }

    private func handleIdentityImageImport(
        _ result: Result<[URL], Error>
    ) {
        switch result {
        case let .success(urls):
            guard let sourceURL = urls.first else { return }
            isPreparingIdentityImage = true
            Task {
                do {
                    let preparedData = try await Task.detached(
                        priority: .userInitiated
                    ) {
                        try SolProfileImageStore.prepareImageData(
                            from: sourceURL
                        )
                    }.value
                    identityCustomAvatarDraftData = preparedData
                    identityAvatarSource = .custom
                } catch {
                    identityErrorMessage = error.localizedDescription
                }
                isPreparingIdentityImage = false
            }
        case let .failure(error):
            let cocoaError = error as NSError
            guard cocoaError.code != NSUserCancelledError else { return }
            identityErrorMessage = error.localizedDescription
        }
    }

    private func chooseKeys() {
        let panel = NSOpenPanel()
        panel.title = "Choose Your Dumped Keys"
        panel.prompt = "Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "keys") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.installKeys(from: url)
    }

    private func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.title = "Choose Your Dumped Firmware"
        panel.message = "Choose a firmware ZIP, XCI, or a folder that directly contains extracted NCA files."
        panel.prompt = "Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .zip,
            UTType(filenameExtension: "xci") ?? .data,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.installFirmware(from: url)
    }

    private func setupFeature(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func setupToggle(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "slider.horizontal.3")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(16)
    }

    private func setupStatusRow(
        title: String,
        detail: String,
        isReady: Bool,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(isReady ? Color.green : Color.orange)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .disabled(viewModel.isBackendOperationRunning)
            }
        }
        .padding(17)
        .modifier(SolOnboardingPanelSurface())
        .shimmering(active: viewModel.isBackendOperationRunning && !reduceMotion)
    }

    private func setupNotice(
        title: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func readinessRow(_ title: String, ready: Bool, optional: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : optional ? "minus.circle" : "exclamationmark.circle.fill")
                .foregroundStyle(ready ? Color.green : optional ? Color.secondary : Color.orange)
                .font(.title3)
                .frame(width: 28)
            Text(title).font(.headline)
            Spacer()
            Text(ready ? "Ready" : optional ? "Optional" : "Required")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(15)
    }
}

private struct SolOnboardingBackground: View {
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            ColorfulView(
                color: [
                    Color(.sRGB, red: 0.025, green: 0.08, blue: 0.18, opacity: 1),
                    Color(.sRGB, red: 0.02, green: 0.28, blue: 0.34, opacity: 1),
                    Color(.sRGB, red: 0.18, green: 0.10, blue: 0.38, opacity: 1),
                    Color(.sRGB, red: 0.015, green: 0.03, blue: 0.08, opacity: 1),
                ],
                speed: .constant(reduceMotion ? 0 : 0.14),
                bias: .constant(0.12),
                noise: .constant(0.01),
                transitionSpeed: .constant(3),
                frameLimit: .constant(reduceMotion ? 1 : 24),
                renderScale: .constant(0.45)
            )
            // ColorfulX currently renders its LAB gradient warm on macOS.
            // Rotate the animated luminance field into Sol's blue/indigo
            // palette while preserving its Metal-backed motion.
            .hueRotation(.degrees(175))
            .saturation(0.78)
            .brightness(-0.06)
            .glur(
                radius: 20,
                offset: 0.26,
                interpolation: 0.58,
                direction: .down,
                noise: 0.01
            )
            .opacity(0.72)

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.66)

            LinearGradient(
                colors: [.black.opacity(0.18), .black.opacity(0.46)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct SolOnboardingWindowSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(
                        cornerRadius: SolGeometry.panelCornerRadius,
                        style: .continuous
                    )
                )
                .shadow(color: .black.opacity(0.28), radius: 34, y: 18)
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(
                        cornerRadius: SolGeometry.panelCornerRadius,
                        style: .continuous
                    )
                )
                .shadow(color: .black.opacity(0.24), radius: 30, y: 16)
        }
    }
}

private struct SolOnboardingPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            Color.secondary.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}
