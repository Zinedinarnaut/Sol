import AuthenticationServices
import SwiftUI

struct SolEngineMultiplayerSettingsPane: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var configuration: SolEngineConfigurationStore
    @ObservedObject var friendsStore: SolFriendsStore

    @Environment(\.colorScheme) private var colorScheme
    @State private var networkInterfaces: [SolNetworkInterface] = [.automatic]
    @State private var passphraseDraft = ""

    var body: some View {
        Group {
            if configuration.isLoaded {
                Form {
                    identitySection
                    multiplayerSection
                    connectionSection

                    Section {
                        Label(
                            "Multiplayer changes apply the next time a game starts.",
                            systemImage: "arrow.clockwise.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .onAppear {
                    passphraseDraft = configuration.multiplayerLDNPassphrase
                    refreshNetworkInterfaces()
                }
            } else {
                ContentUnavailableView(
                    "Multiplayer Configuration Unavailable",
                    systemImage: "person.2.slash",
                    description: Text(
                        configuration.lastError
                            ?? "Build and embed the bundled native Sol Engine runtime."
                    )
                )
            }
        }
    }

    private var identitySection: some View {
        Section("Multiplayer Identity") {
            LabeledContent("Game profile") {
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
                            socialIdentity: friendsStore.identity,
                            size: 28
                        )

                        Picker(
                            "Game profile",
                            selection: Binding(
                                get: { viewModel.selectedProfile?.id ?? "" },
                                set: { profileID in
                                    selectProfile(profileID)
                                }
                            )
                        ) {
                            ForEach(viewModel.backendProfiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    .disabled(
                        viewModel.isBackendOperationRunning ||
                        viewModel.isLaunching
                    )
                }
            }

            LabeledContent("Apple Account") {
                if viewModel.appleAccount.isConnected {
                    Label(
                        viewModel.appleAccount.displayName
                            ?? viewModel.appleAccount.state.title,
                        systemImage: viewModel.appleAccount.state.systemImage
                    )
                    .foregroundStyle(.green)
                } else if viewModel.appleAccount.state == .requiresSignedBuild {
                    Label(
                        viewModel.appleAccount.state.title,
                        systemImage: viewModel.appleAccount.state.systemImage
                    )
                    .foregroundStyle(.secondary)
                } else {
                    SignInWithAppleButton(
                        .signIn,
                        onRequest: { request in
                            viewModel.appleAccount.prepareAuthorizationRequest(request)
                        },
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
                Label(accountError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if viewModel.appleAccount.state == .requiresSignedBuild {
                Label(
                    "A provisioned Apple build enables account and iCloud profile linking.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if viewModel.appleAccount.isConnected,
               let selectedProfile = viewModel.selectedProfile {
                LabeledContent("Account link") {
                    if viewModel.appleAccount.linkedProfileID == selectedProfile.id {
                        Label("Uses \(selectedProfile.name)", systemImage: "link.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Use \(selectedProfile.name)") {
                            viewModel.linkAppleAccountToSelectedProfile()
                        }
                    }
                }
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

            Text(
                "Sol Engine uses the selected game profile as your in-game multiplayer name. The profile link follows Sol through iCloud; private room codes remain on this Mac."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var multiplayerSection: some View {
        Section("Local Wireless Multiplayer") {
            Picker("Mode", selection: binding(\.multiplayerMode)) {
                ForEach(SolEngineMultiplayerMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Text(configuration.multiplayerMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if configuration.multiplayerMode == .onlineRooms {
                Toggle(
                    "Route hosting through the room server",
                    isOn: binding(\.multiplayerDisableP2P)
                )

                Text(
                    "This can help restrictive networks connect, but may add latency."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Private room code") {
                    HStack(spacing: 8) {
                        TextField(
                            "Leave empty for public rooms",
                            text: passphraseBinding
                        )
                        .frame(width: 220)
                        .privacySensitive()

                        Button("Generate") {
                            generatePassphrase()
                        }

                        Button("Clear") {
                            passphraseDraft = ""
                            configuration.multiplayerLDNPassphrase = ""
                        }
                        .disabled(passphraseDraft.isEmpty)
                    }
                }

                if !passphraseDraft.isEmpty, !isPassphraseValid {
                    Label(
                        "Use exactly 16 letters, numbers, or hyphens.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                LabeledContent("Room server") {
                    TextField(
                        "Use Sol Engine default",
                        text: binding(\.multiplayerLDNServer)
                    )
                    .frame(width: 260)
                }
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            Toggle(
                "Allow guest internet access",
                isOn: binding(\.enableInternetAccess)
            )

            if configuration.multiplayerMode != .disabled {
                LabeledContent("Network interface") {
                    HStack(spacing: 8) {
                        Picker(
                            "Network interface",
                            selection: binding(\.multiplayerLanInterfaceID)
                        ) {
                            ForEach(networkInterfaces) { interface in
                                if let detail = interface.detail {
                                    Text("\(interface.name) — \(detail)")
                                        .tag(interface.id)
                                } else {
                                    Text(interface.name)
                                        .tag(interface.id)
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 280)

                        Button {
                            refreshNetworkInterfaces()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh Mac network interfaces")
                    }
                }
            }

            if configuration.multiplayerMode == .onlineRooms,
               !configuration.enableInternetAccess {
                Label(
                    "Online rooms need guest internet access.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var passphraseBinding: Binding<String> {
        Binding(
            get: { passphraseDraft },
            set: { newValue in
                let allowed = CharacterSet(
                    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
                )
                let filtered = newValue.filter {
                    String($0).rangeOfCharacter(from: allowed.inverted) == nil
                }
                passphraseDraft = String(filtered.prefix(16))
                if passphraseDraft.isEmpty || isPassphraseValid {
                    configuration.multiplayerLDNPassphrase = passphraseDraft
                }
            }
        )
    }

    private var isPassphraseValid: Bool {
        passphraseDraft.count == 16
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<SolEngineConfigurationStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { configuration[keyPath: keyPath] = $0 }
        )
    }

    private func selectProfile(_ profileID: String) {
        guard let profile = viewModel.backendProfiles.first(
            where: { $0.id == profileID }
        ) else {
            return
        }
        viewModel.selectProfile(profile)
    }

    private func generatePassphrase() {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(12)
            .lowercased()
        let passphrase = "Sol-\(suffix)"
        passphraseDraft = passphrase
        configuration.multiplayerLDNPassphrase = passphrase
    }

    private func refreshNetworkInterfaces() {
        var refreshed = NetworkInterfaceService.availableInterfaces()
        let selectedID = configuration.multiplayerLanInterfaceID
        if selectedID != "0", !refreshed.contains(where: { $0.id == selectedID }) {
            refreshed.append(
                SolNetworkInterface(
                    id: selectedID,
                    name: selectedID,
                    detail: "Previously selected"
                )
            )
        }
        networkInterfaces = refreshed
    }
}
