import SwiftUI

struct FriendRequestsDetailView: View {
    @ObservedObject var friendsStore: SolFriendsStore

    var body: some View {
        VStack(spacing: 0) {
            ProfileDetailHeader(
                title: "Requests",
                subtitle: "\(friendsStore.requests.count) pending"
            )

            Divider()

            if friendsStore.requests.isEmpty {
                ContentUnavailableView {
                    Label("No Friend Requests", systemImage: "person.crop.circle.badge.checkmark")
                } description: {
                    Text("Requests will appear here when an online Sol Friends provider is connected.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(friendsStore.requests) { request in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle")
                                .font(.title)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(request.displayName)
                                    .font(.headline)
                                Text(request.message ?? "Wants to be friends")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Button("Decline") {
                                try? friendsStore.declineRequest(id: request.id)
                            }
                            Button("Accept") {
                                try? friendsStore.acceptRequest(id: request.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 7)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RecentPlayersDetailView: View {
    @ObservedObject var friendsStore: SolFriendsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ProfileDetailHeader(
                    title: "Recent Players",
                    subtitle: "People encountered in multiplayer"
                )

                Spacer()

                if !friendsStore.recentPlayers.isEmpty {
                    Button("Clear") {
                        friendsStore.clearRecentPlayers()
                    }
                    .padding(.trailing, 34)
                }
            }

            Divider()

            if friendsStore.recentPlayers.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Players", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Sol Engine does not expose stable multiplayer peer identities yet. This page is ready for that provider milestone.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(friendsStore.recentPlayers) { player in
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.title)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.displayName)
                                .font(.headline)
                            Text(player.activity ?? "Multiplayer session")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(player.encounteredAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProfilePrivacyDetailView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var friendsStore: SolFriendsStore

    var body: some View {
        Form {
            Section("Friend Discovery") {
                Toggle(
                    "Allow friend requests",
                    isOn: Binding(
                        get: { friendsStore.identity.allowsFriendRequests },
                        set: { friendsStore.setAllowsFriendRequests($0) }
                    )
                )

                Toggle(
                    "Share play activity with friends",
                    isOn: Binding(
                        get: { friendsStore.identity.sharesPlayActivity },
                        set: { friendsStore.setSharesPlayActivity($0) }
                    )
                )

                Toggle(
                    "Appear in Recent Players",
                    isOn: Binding(
                        get: { friendsStore.identity.appearsInRecentPlayers },
                        set: { friendsStore.setAppearsInRecentPlayers($0) }
                    )
                )
            }

            Section("Storage") {
                LabeledContent("Apple Account") {
                    Label(
                        viewModel.appleAccount.isConnected
                            ? "Authenticated with Apple"
                            : viewModel.appleAccount.state.title,
                        systemImage: viewModel.appleAccount.state.systemImage
                    )
                    .foregroundStyle(
                        viewModel.appleAccount.isConnected
                            ? Color.green
                            : Color.secondary
                    )
                }

                LabeledContent("Friends and requests") {
                    Label("Sol Cloud backup", systemImage: "icloud")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Custom profile image") {
                    Label("Sol Cloud backup", systemImage: "photo.badge.checkmark")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Active game profile") {
                    Label(
                        viewModel.iCloudProfileSync.availability.title,
                        systemImage: viewModel.iCloudProfileSync.availability.systemImage
                    )
                    .foregroundStyle(.secondary)
                }

                Text("When enabled, Sol Cloud backs up this profile, its custom image, friends, requests, recent players, play activity, screenshots, save data, and portable settings. Room codes, keys, firmware, game files, caches, logs, and device paths remain local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SolSettingsLink {
                    Label("Open Multiplayer Settings", systemImage: "gearshape")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
    }
}

struct ProfileDetailHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 62)
        .padding(.vertical, 30)
    }
}
