import SwiftUI

struct ProfileCloudView: View {
    @ObservedObject var cloudSync: SolCloudSyncService
    let appleAccount: AppleAccountService
    let isGameplayActive: Bool

    @State private var confirmsCloudRestore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                statusPanel
                dataPanel
                privacyPanel
            }
            .padding(.horizontal, 56)
            .padding(.top, 36)
            .padding(.bottom, 48)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Replace local Sol data with the latest iCloud snapshot?",
            isPresented: $confirmsCloudRestore
        ) {
            Button("Use iCloud Copy", role: .destructive) {
                cloudSync.useICloud()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sol will first preserve the current saves, profiles, and settings in a local recovery folder.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Sol Cloud")
                    .font(.system(size: 34, weight: .semibold))
                Text("Private backups for the Apple Account connected to this profile")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appleAccount.isConnected {
                Button("Sync Now") {
                    cloudSync.synchronize(reason: .manual)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGameplayActive || isSyncing || requiresAccountReview)
            }
        }
    }

    private var statusPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: cloudSync.state.systemImage)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(cloudSync.state.title)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(16)

            Divider().padding(.leading, 58)

            Toggle(
                "Back up automatically",
                isOn: $cloudSync.automaticSyncEnabled
            )
            .disabled(!appleAccount.isConnected)
            .padding(16)

            if case .conflict = cloudSync.state {
                Divider().padding(.leading, 58)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This Mac and iCloud both changed")
                            .font(.headline)
                        Text("Choose a copy. Sol never silently overwrites divergent save data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Keep This Mac") {
                        cloudSync.keepThisMac()
                    }
                    .disabled(isGameplayActive)

                    Button("Use iCloud") {
                        confirmsCloudRestore = true
                    }
                    .disabled(isGameplayActive)
                }
                .padding(16)
            }

            if case .accountChangeReview = cloudSync.state {
                Divider().padding(.leading, 58)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local data was used with another Apple Account")
                            .font(.headline)
                        Text("Choose whether to back up this Mac to the new account or restore that account’s existing Sol data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Back Up This Mac") {
                        cloudSync.keepThisMac()
                    }
                    .disabled(isGameplayActive)

                    Button("Use iCloud") {
                        confirmsCloudRestore = true
                    }
                    .disabled(isGameplayActive)
                }
                .padding(16)
            }

            if cloudSync.lastRecoveryURL != nil {
                Divider().padding(.leading, 58)
                Button("Show Last Recovery Copy") {
                    cloudSync.revealRecoveryFolder()
                }
                .buttonStyle(.link)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(
                cornerRadius: SolGeometry.cardCornerRadius,
                style: .continuous
            )
        )
    }

    private var dataPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Included Data")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let latestBackup = cloudSync.latestBackup {
                    Text(ByteCountFormatter.string(fromByteCount: latestBackup.totalByteCount, countStyle: .file))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(SolCloudDataCategory.allCases, id: \.self) { category in
                    HStack(spacing: 12) {
                        Image(systemName: category.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(category.title)
                        Spacer()
                        if let count = cloudSync.latestBackup?.counts[category] {
                            Text(count, format: .number)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 12)

                    if category != SolCloudDataCategory.allCases.last {
                        Divider().padding(.leading, 49)
                    }
                }
            }
            .background(
                Color.secondary.opacity(0.08),
                in: RoundedRectangle(
                    cornerRadius: SolGeometry.cardCornerRadius,
                    style: .continuous
                )
            )

            HStack {
                if let backup = cloudSync.latestBackup {
                    Text("Latest snapshot \(backup.createdAt, format: .relative(presentation: .named))")
                } else {
                    Text("The first snapshot is created after Apple Account and iCloud are available.")
                }
                Spacer()
                Button("Back Up Now") {
                    cloudSync.backUpNow()
                }
                .disabled(!appleAccount.isConnected || isGameplayActive || isSyncing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var privacyPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Kept on this Mac", systemImage: "lock.shield")
                .font(.headline)

            Text("Keys, firmware, game files, caches, shader data, logs, device paths, security bookmarks, controller identifiers, and multiplayer passphrases are never included in Sol Cloud.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Sign in with Apple identifies the Sol profile. macOS iCloud provides the private storage account; the two accounts are checked separately.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(
                cornerRadius: SolGeometry.cardCornerRadius,
                style: .continuous
            )
        )
    }

    private var isSyncing: Bool {
        if case .syncing = cloudSync.state { return true }
        return false
    }

    private var requiresAccountReview: Bool {
        if case .accountChangeReview = cloudSync.state { return true }
        return false
    }

    private var statusColor: Color {
        switch cloudSync.state {
        case .synced: .green
        case .accountChangeReview, .conflict, .failed: .orange
        default: .secondary
        }
    }

    private var statusDetail: String {
        switch cloudSync.state {
        case .waitingForAppleAccount:
            "Connect with Apple from your profile before cloud data is opened."
        case .waitingForICloud:
            "Sign in to iCloud in System Settings, then return to Sol."
        case .requiresSignedBuild:
            "This build does not contain the required iCloud container entitlement."
        case .ready:
            "Sol is ready to create or restore a cloud snapshot."
        case .accountChangeReview:
            "Automatic sync is paused so one account’s local data is not uploaded to another account without your approval."
        case .deferredForGame:
            "Save files are never read or replaced while Sol Engine is running."
        case .syncing:
            "Files are verified by content hash before the snapshot is committed."
        case .synced(let date):
            "Last checked \(date.formatted(.relative(presentation: .named)))."
        case .conflict(let date):
            "The iCloud copy was updated \(date.formatted(.relative(presentation: .named)))."
        case .failed(let message):
            message
        }
    }
}
