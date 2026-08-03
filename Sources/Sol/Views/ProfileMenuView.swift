import AppKit
import SwiftUI

struct ProfileMenuView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ProfileAvatarView(
                profile: viewModel.selectedProfile,
                generatedAvatarURL: viewModel.appleAccount.avatarURL,
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
                isPresented: $isPresented
            )
            .frame(width: 292)
        }
        .help(viewModel.selectedProfile.map { "\($0.name) profile" } ?? "Profiles and Settings")
        .accessibilityLabel(
            viewModel.selectedProfile.map { "Profile: \($0.name)" } ?? "Profiles and Settings"
        )
        .accessibilityHint("Shows profiles, account status, and Settings")
    }
}

private struct ProfilePopoverView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ProfileAvatarView(
                    profile: viewModel.selectedProfile,
                    generatedAvatarURL: viewModel.appleAccount.avatarURL,
                    size: 36
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedProfile?.name ?? "Sol Profile")
                        .font(.headline)
                        .lineLimit(1)

                    Text("Player profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(14)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles")
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
                            title: profile.name,
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
                        title: "Multiplayer as \(profile.name)",
                        systemImage: "person.2.circle"
                    )
                }
            }
            .padding(12)

            Divider()

            HStack(spacing: 6) {
                Button {
                    viewModel.refreshProfiles()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isBackendOperationRunning || viewModel.isLaunching)

                Spacer(minLength: 8)

                SettingsLink {
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
}

struct ProfileAvatarView: View {
    let profile: SolEngineProfile?
    var generatedAvatarURL: URL? = nil
    let size: CGFloat

    var body: some View {
        Group {
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
                        fallbackAvatar
                    @unknown default:
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(.primary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fallbackAvatar: some View {
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
