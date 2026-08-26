import AppKit
import SwiftUI

struct ProfileMenuView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var friendsStore: SolFriendsStore
    let onOpenProfile: () -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ProfileAvatarView(
                profile: viewModel.selectedProfile,
                generatedAvatarURL: viewModel.appleAccount.avatarURL,
                socialIdentity: friendsStore.identity,
                size: 22
            )
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .contentShape(Rectangle())
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ProfilePopoverView(
                viewModel: viewModel,
                friendsStore: friendsStore,
                isPresented: $isPresented,
                onOpenProfile: onOpenProfile
            )
            .frame(width: 292)
        }
        .help("\(friendsStore.identity.displayName) profile")
        .accessibilityLabel("Profile: \(friendsStore.identity.displayName)")
        .accessibilityHint("Shows your profile, account status, and Settings")
    }
}

private struct ProfilePopoverView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var friendsStore: SolFriendsStore
    @Binding var isPresented: Bool
    let onOpenProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ProfileAvatarView(
                    profile: viewModel.selectedProfile,
                    generatedAvatarURL: viewModel.appleAccount.avatarURL,
                    socialIdentity: friendsStore.identity,
                    size: 36
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(friendsStore.identity.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    Text("Sol profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(14)

            Divider()

            Button {
                isPresented = false
                onOpenProfile()
            } label: {
                HStack(spacing: 9) {
                    Label("Open Profile", systemImage: "person.crop.circle")
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Game Users")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                if viewModel.backendProfiles.isEmpty {
                    profileAction(
                        title: "Refresh Profiles",
                        systemImage: "arrow.clockwise"
                    ) {
                        viewModel.refreshProfiles()
                    }
                    .disabled(viewModel.isBackendOperationRunning || viewModel.isLaunching)
                } else {
                    ForEach(viewModel.backendProfiles) { profile in
                        profileAction(
                            title: displayedGameUserName(profile),
                            systemImage: profile.isDefault
                                ? "checkmark.circle.fill"
                                : "person.crop.circle"
                        ) {
                            isPresented = false
                            viewModel.selectProfile(profile)
                        }
                        .disabled(profile.isDefault || viewModel.isLaunching)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    title: viewModel.iCloudProfileSync.availability.title,
                    systemImage: viewModel.iCloudProfileSync.availability.systemImage
                )

                statusRow(
                    title: viewModel.appleAccount.displayName
                        ?? viewModel.appleAccount.state.title,
                    systemImage: viewModel.appleAccount.state.systemImage
                )

                if viewModel.appleAccount.isConnected,
                   let profile = viewModel.selectedProfile {
                    statusRow(
                        title: "Multiplayer as \(displayedGameUserName(profile))",
                        systemImage: "person.2.circle"
                    )
                }
            }
            .padding(12)

            Divider()

            HStack(spacing: 6) {
                Button {
                    Task {
                        await viewModel.updateService.checkForUpdates(force: true)
                    }
                } label: {
                    Label("Updates", systemImage: "arrow.down.circle")
                }
                .disabled(viewModel.updateService.isDownloading)

                Button {
                    viewModel.refreshProfiles()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isBackendOperationRunning || viewModel.isLaunching)

                Spacer(minLength: 8)

                SolSettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
            }
            .controlSize(.small)
            .padding(10)
        }
    }

    private func profileAction(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func statusRow(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func displayedGameUserName(_ profile: SolEngineProfile) -> String {
        guard profile.name.compare(
            "RyuPlayer",
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame else {
            return profile.name
        }
        return friendsStore.identity.displayName
    }
}

struct ProfileAvatarView: View {
    let profile: SolEngineProfile?
    var generatedAvatarURL: URL? = nil
    var socialIdentity: SolSocialIdentity? = nil
    var customAvatarOverride: NSImage? = nil
    let size: CGFloat

    var body: some View {
        avatarContent
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(.primary.opacity(0.18), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if socialIdentity?.avatarSource == .pixel,
           let identity = socialIdentity {
            SolPixelAvatarImage(
                avatar: identity.resolvedPixelAvatar,
                size: size
            )
        } else if socialIdentity?.avatarSource == .custom {
            customAvatar
        } else if socialIdentity?.avatarSource == .gameProfile {
            gameProfileAvatar
        } else if socialIdentity?.avatarSource == .apple {
            accountAvatar
        } else if generatedAvatarURL != nil {
            accountAvatar
        } else {
            gameProfileAvatar
        }
    }

    @ViewBuilder
    private var customAvatar: some View {
        if let customAvatarOverride {
            Image(nsImage: customAvatarOverride)
                .resizable()
                .scaledToFill()
        } else if let identity = socialIdentity,
                  let revision = identity.customAvatarRevision,
                  let image = SolProfileImageStore.shared.image(
                      profileID: identity.localProfileID,
                      revision: revision
                  ) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else if let identity = socialIdentity {
            SolPixelAvatarImage(
                avatar: identity.resolvedPixelAvatar,
                size: size
            )
        } else {
            gameProfileAvatar
        }
    }

    @ViewBuilder
    private var accountAvatar: some View {
        if let generatedAvatarURL {
            AsyncImage(
                url: generatedAvatarURL,
                transaction: Transaction(animation: .easeInOut(duration: 0.2))
            ) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty, .failure:
                    gameProfileAvatar
                @unknown default:
                    gameProfileAvatar
                }
            }
        } else {
            gameProfileAvatar
        }
    }

    @ViewBuilder
    private var gameProfileAvatar: some View {
        if let data = profile?.imageData,
           let image = NSImage(data: data) {
            Image(nsImage: normalizedImage(image))
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }

    private func normalizedImage(_ image: NSImage) -> NSImage {
        let normalized = image.copy() as? NSImage ?? image
        normalized.size = NSSize(width: size, height: size)
        return normalized
    }
}
