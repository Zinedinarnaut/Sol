import SwiftUI

enum ProfileDestination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case captures
    case activity
    case saves
    case gameUsers
    case cloud
    case friends
    case requests
    case recentPlayers
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .captures: "Captures"
        case .activity: "Activity"
        case .saves: "Save Vault"
        case .gameUsers: "Game Users"
        case .cloud: "Sol Cloud"
        case .friends: "Friends"
        case .requests: "Requests"
        case .recentPlayers: "Recent Players"
        case .privacy: "Privacy"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "person.crop.circle"
        case .captures: "photo.on.rectangle.angled"
        case .activity: "waveform.path.ecg"
        case .saves: "externaldrive.badge.timemachine"
        case .gameUsers: "person.2.crop.square.stack"
        case .cloud: "icloud"
        case .friends: "person.2"
        case .requests: "person.crop.circle.badge.plus"
        case .recentPlayers: "clock.arrow.circlepath"
        case .privacy: "hand.raised"
        }
    }
}

struct ProfileHubView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var friendsStore: SolFriendsStore

    @State private var selection: ProfileDestination? = .overview
    @State private var isEditingProfile = false
    @State private var isAddingFriend = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: sidebarWidth(for: geometry.size.width))
                    .modifier(ProfileSidebarSurface())
                    .padding(.leading, 10)
                    .padding(.vertical, 10)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .sheet(isPresented: $isEditingProfile) {
            ProfileEditorSheet(
                viewModel: viewModel,
                friendsStore: friendsStore
            )
        }
        .sheet(isPresented: $isAddingFriend) {
            AddLocalFriendSheet(friendsStore: friendsStore)
        }
        .alert("Friends Couldn’t Be Updated", isPresented: friendsErrorBinding) {
            Button("OK", role: .cancel) {
                friendsStore.clearLastError()
            }
        } message: {
            Text(friendsStore.lastError ?? "Try again.")
        }
        .onAppear(perform: prepareProfile)
        .onChange(of: viewModel.selectedProfile?.id) { _, _ in
            prepareProfile()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ProfileAvatarView(
                    profile: viewModel.selectedProfile,
                    generatedAvatarURL: viewModel.appleAccount.avatarURL,
                    socialIdentity: friendsStore.identity,
                    size: 132
                )

                VStack(spacing: 4) {
                    Text(friendsStore.identity.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)

                    Text(profileSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
            .padding(.horizontal, 20)
            .padding(.bottom, 26)

            List(selection: $selection) {
                Section {
                    navigationRow(.overview)
                    navigationRow(.captures)
                    navigationRow(.activity)
                    navigationRow(.saves)
                    navigationRow(.gameUsers)
                }

                Section {
                    navigationRow(.friends)
                    navigationRow(.requests, badge: friendsStore.requests.count)
                    navigationRow(.recentPlayers)
                }

                Section {
                    navigationRow(.cloud)
                    navigationRow(.privacy)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    viewModel.cloudSync.state.title,
                    systemImage: viewModel.cloudSync.state.systemImage
                )
                .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: SolGeometry.panelCornerRadius,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            ProfileOverviewView(
                viewModel: viewModel,
                friendsStore: friendsStore,
                onEditProfile: { isEditingProfile = true },
                onShowFriends: { selection = .friends }
            )
        case .captures:
            ProfileCapturesView(
                library: viewModel.screenshotLibrary,
                cloudSync: viewModel.cloudSync
            )
        case .activity:
            ProfileActivityView(
                library: viewModel.playActivityLibrary,
                games: viewModel.games
            )
        case .saves:
            ProfileSaveVaultView(
                vault: viewModel.saveVault,
                isGameplayActive: viewModel.isLaunching
            )
        case .gameUsers:
            ProfileGameUsersView(viewModel: viewModel)
        case .cloud:
            ProfileCloudView(
                cloudSync: viewModel.cloudSync,
                appleAccount: viewModel.appleAccount,
                isGameplayActive: viewModel.isLaunching
            )
        case .friends:
            FriendsDetailView(
                friendsStore: friendsStore,
                onAddFriend: { isAddingFriend = true }
            )
        case .requests:
            FriendRequestsDetailView(friendsStore: friendsStore)
        case .recentPlayers:
            RecentPlayersDetailView(friendsStore: friendsStore)
        case .privacy:
            ProfilePrivacyDetailView(
                viewModel: viewModel,
                friendsStore: friendsStore
            )
        }
    }

    private var profileSubtitle: String {
        if viewModel.appleAccount.isConnected,
           let displayName = viewModel.appleAccount.displayName {
            return displayName
        }
        guard let engineName = viewModel.selectedProfile?.name,
              engineName.compare(
                "RyuPlayer",
                options: [.caseInsensitive, .diacriticInsensitive]
              ) != .orderedSame,
              engineName.compare(
                friendsStore.identity.displayName,
                options: [.caseInsensitive, .diacriticInsensitive]
              ) != .orderedSame else {
            return "Local Sol profile"
        }
        return engineName
    }

    private var friendsErrorBinding: Binding<Bool> {
        Binding(
            get: { friendsStore.lastError != nil },
            set: { if !$0 { friendsStore.clearLastError() } }
        )
    }

    private func navigationRow(
        _ destination: ProfileDestination,
        badge: Int = 0
    ) -> some View {
        HStack(spacing: 9) {
            Label(destination.title, systemImage: destination.systemImage)
            Spacer(minLength: 8)

            if badge > 0 {
                Text(badge, format: .number)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        .quaternary,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .accessibilityLabel("\(badge) pending")
            }
        }
        .font(.system(size: 16, weight: .regular))
        .padding(.vertical, 7)
        .tag(destination)
    }

    private func sidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.23, 272), 336)
    }

    private func prepareProfile() {
        let defaultName = viewModel.appleAccount.displayName
            ?? "Sol Player"
        friendsStore.prepareIdentity(defaultDisplayName: defaultName)

        if viewModel.backendProfiles.isEmpty,
           !viewModel.isBackendOperationRunning,
           !viewModel.isLaunching {
            viewModel.refreshProfiles()
        }
    }
}

private struct ProfileSidebarSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    Color.clear
                        .glassEffect(
                            .regular.interactive(),
                            in: RoundedRectangle(
                                cornerRadius: SolGeometry.panelCornerRadius,
                                style: .continuous
                            )
                        )
                }
                .background(
                    Color.secondary.opacity(0.045),
                    in: RoundedRectangle(
                        cornerRadius: SolGeometry.panelCornerRadius,
                        style: .continuous
                    )
                )
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(
                        cornerRadius: SolGeometry.panelCornerRadius,
                        style: .continuous
                    )
                )
                .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
        }
    }
}
