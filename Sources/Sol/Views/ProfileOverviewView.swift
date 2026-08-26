import SwiftUI

struct ProfileOverviewView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var friendsStore: SolFriendsStore

    let onEditProfile: () -> Void
    let onShowFriends: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                profileHeader
                accountStatus
                Divider()
                playActivity
                Divider()
                friendsPreview
            }
            .padding(.horizontal, 62)
            .padding(.top, 36)
            .padding(.bottom, 42)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var profileHeader: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(friendsStore.identity.displayName)
                    .font(.system(size: 38, weight: .semibold))
                    .lineLimit(1)

                Text(profileSubtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 20)

            Button("Edit Profile", action: onEditProfile)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(minHeight: 108)
    }

    private var accountStatus: some View {
        VStack(spacing: 0) {
            statusRow(
                title: "iCloud",
                detail: viewModel.cloudSync.state.title,
                systemImage: viewModel.cloudSync.state.systemImage
            )

            Divider()
                .padding(.leading, 44)

            statusRow(
                title: "Stored on this Mac",
                detail: localStorageDetail,
                systemImage: "laptopcomputer"
            )
        }
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var playActivity: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Play Activity")
                .font(.title2.weight(.semibold))

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 72) {
                    playtimeSummary
                    recentGameSummary
                }

                VStack(alignment: .leading, spacing: 22) {
                    playtimeSummary
                    recentGameSummary
                }
            }
        }
    }

    private var playtimeSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Total Playtime")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(formattedTotalPlaytime)
                .font(.title.weight(.semibold))
                .monospacedDigit()

            Text("Across \(playedGameCount) played \(playedGameCount == 1 ? "game" : "games")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private var recentGameSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Recently Played")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let game = mostRecentGame {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(game.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(game.formattedLastPlayed ?? "Recently")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "gamecontroller")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No play activity yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    private var friendsPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Friends")
                    .font(.title2.weight(.semibold))

                Text(friendsStore.friends.count, format: .number)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("See All", action: onShowFriends)
                    .buttonStyle(.link)
            }

            if friendsStore.friends.isEmpty {
                ContentUnavailableView {
                    Label("No Friends Yet", systemImage: "person.2")
                } description: {
                    Text("Add local friends now. Online requests and presence will arrive with the Sol Friends provider.")
                } actions: {
                    Button("Open Friends", action: onShowFriends)
                }
                .frame(maxWidth: .infinity, minHeight: 210)
                .background(
                    Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(friendsStore.friends.prefix(5))) { friend in
                        FriendRow(friend: friend, friendsStore: friendsStore)

                        if friend.id != friendsStore.friends.prefix(5).last?.id {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .background(
                    Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
        }
    }

    private var playedGameCount: Int {
        viewModel.games.filter { $0.hoursPlayed > 0 }.count
    }

    private var mostRecentGame: Game? {
        viewModel.games
            .filter { $0.lastPlayed != nil }
            .max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
    }

    private var formattedTotalPlaytime: String {
        let totalMinutes = max(
            Int((viewModel.games.reduce(0) { $0 + $1.hoursPlayed } * 60).rounded()),
            0
        )
        guard totalMinutes > 0 else { return "Not played" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) hr" }
        return "\(hours) hr \(minutes) min"
    }

    private var profileSubtitle: String {
        let status = friendsStore.identity.statusMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty {
            return status
        }
        if let appleName = viewModel.appleAccount.displayName, !appleName.isEmpty {
            return appleName
        }
        return "Local Sol profile"
    }

    private var localStorageDetail: String {
        let count = friendsStore.friends.count
        let captures = viewModel.screenshotLibrary.screenshots.count
        return "\(count) friends · \(captures) captures"
    }

    private func statusRow(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
            Spacer(minLength: 12)
            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
