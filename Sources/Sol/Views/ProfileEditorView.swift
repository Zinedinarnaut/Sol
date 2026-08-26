import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditorSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var friendsStore: SolFriendsStore

    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var statusMessage: String
    @State private var selectedProfileID: String
    @State private var allowsFriendRequests: Bool
    @State private var sharesPlayActivity: Bool
    @State private var appearsInRecentPlayers: Bool
    @State private var avatarSource: SolProfileAvatarSource
    @State private var selectedPixelAvatar: SolPixelAvatar
    @State private var customAvatarRevision: UUID?
    @State private var customAvatarDraftData: Data?
    @State private var isChoosingCustomImage = false
    @State private var isPreparingCustomImage = false
    @State private var errorMessage: String?

    private let originalCustomAvatarRevision: UUID?

    init(
        viewModel: LauncherViewModel,
        friendsStore: SolFriendsStore
    ) {
        self.viewModel = viewModel
        self.friendsStore = friendsStore
        _displayName = State(initialValue: friendsStore.identity.displayName)
        _statusMessage = State(initialValue: friendsStore.identity.statusMessage)
        _selectedProfileID = State(initialValue: viewModel.selectedProfile?.id ?? "")
        _allowsFriendRequests = State(initialValue: friendsStore.identity.allowsFriendRequests)
        _sharesPlayActivity = State(initialValue: friendsStore.identity.sharesPlayActivity)
        _appearsInRecentPlayers = State(initialValue: friendsStore.identity.appearsInRecentPlayers)
        _avatarSource = State(
            initialValue: friendsStore.identity.avatarSource
                ?? (viewModel.appleAccount.avatarURL == nil ? .gameProfile : .apple)
        )
        _selectedPixelAvatar = State(
            initialValue: friendsStore.identity.resolvedPixelAvatar
        )
        _customAvatarRevision = State(
            initialValue: friendsStore.identity.customAvatarRevision
        )
        _customAvatarDraftData = State(initialValue: nil)
        originalCustomAvatarRevision = friendsStore.identity.customAvatarRevision
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    LabeledContent("Display name") {
                        TextField("Sol Player", text: $displayName)
                            .labelsHidden()
                            .frame(width: 240)
                    }

                    LabeledContent("Status") {
                        TextField("Available to play", text: $statusMessage)
                            .labelsHidden()
                            .frame(width: 240)
                    }
                }

                Section("Profile Picture") {
                    HStack(alignment: .center, spacing: 16) {
                        ProfileAvatarView(
                            profile: selectedGameProfile,
                            generatedAvatarURL: viewModel.appleAccount.avatarURL,
                            socialIdentity: avatarPreviewIdentity,
                            customAvatarOverride: customAvatarDraftImage,
                            size: 82
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            Text(avatarSource.title)
                                .font(.headline)

                            Text(avatarSourceDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)

                    Picker("Source", selection: $avatarSource) {
                        ForEach(SolProfileAvatarSource.allCases) { source in
                            Label(source.title, systemImage: source.systemImage)
                                .tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    if avatarSource == .pixel {
                        SolPixelAvatarPicker(selection: $selectedPixelAvatar)
                            .padding(.vertical, 4)
                    } else if avatarSource == .custom {
                        customImageControls
                    } else if avatarSource == .apple,
                              viewModel.appleAccount.avatarURL == nil {
                        Label(
                            "Connect an Apple Account in Settings to use this source. Sol will show the game-profile image until then.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if avatarSource == .gameProfile,
                              selectedGameProfile == nil {
                        Label(
                            "Load or create a Sol Engine game profile to use its image.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Game Profile") {
                    if viewModel.backendProfiles.isEmpty {
                        LabeledContent("Sol Engine profile") {
                            Button("Load Profiles") {
                                viewModel.refreshProfiles()
                            }
                            .disabled(viewModel.isBackendOperationRunning)
                        }
                    } else {
                        LabeledContent("Sol Engine profile") {
                            Picker("Sol Engine profile", selection: $selectedProfileID) {
                                ForEach(viewModel.backendProfiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }
                    }

                    Text("Sol uses this name and picture in Home, Profile, Friends, multiplayer, cloud restore, and the active Sol Engine game user.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Toggle("Allow friend requests", isOn: $allowsFriendRequests)
                    Toggle("Share play activity", isOn: $sharesPlayActivity)
                    Toggle("Appear in Recent Players", isOn: $appearsInRecentPlayers)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaveDisabled)
            }
            .padding(16)
        }
        .frame(width: 700, height: 760)
        .navigationTitle("Edit Profile")
        .fileImporter(
            isPresented: $isChoosingCustomImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleCustomImageImport
        )
        .alert("Profile Couldn’t Be Saved", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Try again.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        let profileID = friendsStore.identity.localProfileID
        var savedCustomRevision = customAvatarRevision
        var stagedRevision: UUID?

        do {
            if let customAvatarDraftData {
                let revision = try SolProfileImageStore.shared.savePreparedImage(
                    customAvatarDraftData,
                    profileID: profileID
                )
                stagedRevision = revision
                savedCustomRevision = revision
            }

            try friendsStore.updateIdentity(
                displayName: displayName,
                statusMessage: statusMessage,
                allowsFriendRequests: allowsFriendRequests,
                sharesPlayActivity: sharesPlayActivity,
                appearsInRecentPlayers: appearsInRecentPlayers,
                avatarSource: avatarSource,
                pixelAvatar: selectedPixelAvatar,
                customAvatarRevision: savedCustomRevision
            )

            // Select the requested game user first. Identity mirroring queues
            // behind that backend operation, so the new name and picture land
            // on the profile the user actually chose in this sheet.
            if let profile = viewModel.backendProfiles.first(where: { $0.id == selectedProfileID }),
               !profile.isDefault {
                viewModel.selectProfile(profile)
            }

            viewModel.synchronizeSolIdentityToSelectedProfile(
                displayName: displayName,
                image: gameProfileSyncImage(
                    customRevision: savedCustomRevision
                ),
                remoteImageURL: avatarSource == .apple
                    ? viewModel.appleAccount.avatarURL
                    : nil
            )

            if let originalCustomAvatarRevision,
               originalCustomAvatarRevision != savedCustomRevision {
                try? SolProfileImageStore.shared.removeImage(
                    profileID: profileID,
                    revision: originalCustomAvatarRevision
                )
            }
            dismiss()
        } catch {
            if let stagedRevision {
                try? SolProfileImageStore.shared.removeImage(
                    profileID: profileID,
                    revision: stagedRevision
                )
            }
            errorMessage = error.localizedDescription
        }
    }

    private var selectedGameProfile: SolEngineProfile? {
        viewModel.backendProfiles.first(where: { $0.id == selectedProfileID })
            ?? viewModel.selectedProfile
    }

    private var avatarPreviewIdentity: SolSocialIdentity {
        var identity = friendsStore.identity
        identity.avatarSource = avatarSource
        identity.pixelAvatar = selectedPixelAvatar
        identity.customAvatarRevision = customAvatarRevision
        return identity
    }

    private var customAvatarDraftImage: NSImage? {
        customAvatarDraftData.flatMap(NSImage.init(data:))
    }

    private func gameProfileSyncImage(
        customRevision: UUID?
    ) -> NSImage? {
        switch avatarSource {
        case .pixel:
            return SolPixelAvatarRenderer.shared.image(
                for: selectedPixelAvatar,
                dimension: 256
            )
        case .custom:
            if let customAvatarDraftImage {
                return customAvatarDraftImage
            }
            guard let customRevision else { return nil }
            return SolProfileImageStore.shared.image(
                profileID: friendsStore.identity.localProfileID,
                revision: customRevision
            )
        case .apple:
            // The Apple source is rendered from its stable account URL in Sol.
            // Avoid blocking profile saves on a network fetch.
            return nil
        case .gameProfile:
            return selectedGameProfile?.imageData.flatMap(NSImage.init(data:))
        }
    }

    private var hasCustomImage: Bool {
        if customAvatarDraftData != nil {
            return true
        }
        guard let customAvatarRevision else { return false }
        return SolProfileImageStore.shared.containsImage(
            profileID: friendsStore.identity.localProfileID,
            revision: customAvatarRevision
        )
    }

    private var isSaveDisabled: Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isPreparingCustomImage
            || (avatarSource == .custom && !hasCustomImage)
    }

    private var customImageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(hasCustomImage ? "Replace Image…" : "Choose Image…") {
                    isChoosingCustomImage = true
                }
                .disabled(isPreparingCustomImage)

                if isPreparingCustomImage {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing image…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if hasCustomImage {
                    Button("Remove", role: .destructive) {
                        customAvatarDraftData = nil
                        customAvatarRevision = nil
                        avatarSource = .pixel
                    }
                    .disabled(isPreparingCustomImage)
                }
            }

            Label(
                "PNG, JPEG, HEIC, and WebP are accepted up to 25 MB. Sol center-crops the image and removes its metadata before storing it locally.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func handleCustomImageImport(
        _ result: Result<[URL], Error>
    ) {
        switch result {
        case let .success(urls):
            guard let sourceURL = urls.first else { return }
            isPreparingCustomImage = true
            Task {
                do {
                    let preparedData = try await Task.detached(
                        priority: .userInitiated
                    ) {
                        try SolProfileImageStore.prepareImageData(
                            from: sourceURL
                        )
                    }.value
                    customAvatarDraftData = preparedData
                    avatarSource = .custom
                } catch {
                    errorMessage = error.localizedDescription
                }
                isPreparingCustomImage = false
            }
        case let .failure(error):
            let cocoaError = error as NSError
            guard cocoaError.code != NSUserCancelledError else { return }
            errorMessage = error.localizedDescription
        }
    }

    private var avatarSourceDescription: String {
        switch avatarSource {
        case .pixel:
            "A unique pixel avatar generated locally by Sol."
        case .custom:
            "Uses a photo or image you choose from this Mac."
        case .apple:
            "Uses the avatar associated with your connected Apple Account."
        case .gameProfile:
            "Uses the image stored with your active Sol Engine profile."
        }
    }
}

struct AddLocalFriendSheet: View {
    @ObservedObject var friendsStore: SolFriendsStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Local Friend")
                        .font(.title2.weight(.semibold))
                    Text("This entry stays on your Mac until Sol Friends has an online provider.")
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                LabeledContent("Display name") {
                    TextField("Friend name", text: $displayName)
                        .labelsHidden()
                        .frame(width: 250)
                }

                LabeledContent("Note") {
                    TextField("Optional", text: $note)
                        .labelsHidden()
                        .frame(width: 250)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Friend", action: addFriend)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520, height: 300)
        .alert("Friend Couldn’t Be Added", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Try again.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func addFriend() {
        do {
            try friendsStore.addLocalFriend(displayName: displayName, note: note)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
