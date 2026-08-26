import SwiftUI

struct FriendsDetailView: View {
    @ObservedObject var friendsStore: SolFriendsStore
    let onAddFriend: () -> Void

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Friends")
                        .font(.largeTitle.weight(.semibold))
                    Text("\(friendsStore.friends.count) local \(friendsStore.friends.count == 1 ? "friend" : "friends")")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                TextField("Search Friends", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)

                Button(action: onAddFriend) {
                    Label("Add Friend", systemImage: "person.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 62)
            .padding(.vertical, 30)

            Divider()

            if filteredFriends.isEmpty {
                ContentUnavailableView {
                    Label(
                        searchText.isEmpty ? "No Friends Yet" : "No Matches",
                        systemImage: searchText.isEmpty ? "person.2" : "magnifyingglass"
                    )
                } description: {
                    Text(
                        searchText.isEmpty
                            ? "Add someone to your local Friends list. Online presence and requests require the future Sol Friends provider."
                            : "Try another name or note."
                    )
                } actions: {
                    if searchText.isEmpty {
                        Button("Add Friend", action: onAddFriend)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredFriends.enumerated()), id: \.element.id) { index, friend in
                            if index > 0 {
                                Divider()
                                    .padding(.leading, 58)
                            }

                            FriendRow(friend: friend, friendsStore: friendsStore)
                        }
                    }
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .padding(.horizontal, 62)
                    .padding(.vertical, 28)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var filteredFriends: [SolFriend] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return friendsStore.friends }
        return friendsStore.friends.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
                $0.note.localizedCaseInsensitiveContains(query)
        }
    }
}

struct FriendRow: View {
    let friend: SolFriend
    @ObservedObject var friendsStore: SolFriendsStore

    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(friend.displayName)
                        .font(.headline)

                    if friend.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }

                Text(friendDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Label(friend.presence.title, systemImage: friend.presence.systemImage)
                .font(.caption)
                .foregroundStyle(friend.presence.color)
                .labelStyle(.titleAndIcon)

            Menu {
                Button(
                    friend.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: friend.isFavorite ? "star.slash" : "star"
                ) {
                    try? friendsStore.setFavorite(!friend.isFavorite, friendID: friend.id)
                }

                Divider()

                Button(
                    "Remove Friend",
                    systemImage: "person.crop.circle.badge.minus",
                    role: .destructive
                ) {
                    isConfirmingRemoval = true
                }
            } label: {
                Label("Friend Actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Remove \(friend.displayName)?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Remove Friend", role: .destructive) {
                try? friendsStore.removeFriend(id: friend.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes the local Sol Friends entry.")
        }
    }

    private var friendDetail: String {
        if let lastActivity = friend.lastActivity, !lastActivity.isEmpty {
            return lastActivity
        }
        if !friend.note.isEmpty {
            return friend.note
        }
        if let lastSeen = friend.lastSeen {
            return "Last seen \(lastSeen.formatted(.relative(presentation: .named)))"
        }
        return "Local friend"
    }
}

extension SolFriendPresence {
    var title: String {
        switch self {
        case .online: "Online"
        case .away: "Away"
        case .offline: "Offline"
        }
    }

    var systemImage: String {
        switch self {
        case .online: "circle.fill"
        case .away: "moon.fill"
        case .offline: "circle"
        }
    }

    var color: Color {
        switch self {
        case .online: .green
        case .away: .orange
        case .offline: .secondary
        }
    }
}
