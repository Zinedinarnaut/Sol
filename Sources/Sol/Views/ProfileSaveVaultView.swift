import SwiftUI

struct ProfileSaveVaultView: View {
    @ObservedObject var vault: SolSaveVaultService
    let isGameplayActive: Bool

    @State private var restoreCandidate: SolSaveSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if vault.snapshots.isEmpty {
                ContentUnavailableView {
                    Label("No Save Snapshots", systemImage: "externaldrive.badge.timemachine")
                } description: {
                    Text("Sol creates an automatic restore point after gameplay. You can make one now, too.")
                } actions: {
                    Button("Create Snapshot", action: vault.createSnapshot)
                        .buttonStyle(.borderedProminent)
                        .disabled(isGameplayActive || vault.isWorking)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vault.snapshots) { snapshot in
                    snapshotRow(snapshot)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: vault.reload)
        .confirmationDialog(
            "Restore this save snapshot?",
            isPresented: Binding(
                get: { restoreCandidate != nil },
                set: { if !$0 { restoreCandidate = nil } }
            ),
            presenting: restoreCandidate
        ) { snapshot in
            Button("Restore Saves", role: .destructive) {
                vault.restore(snapshot)
                restoreCandidate = nil
            }
            Button("Cancel", role: .cancel) {
                restoreCandidate = nil
            }
        } message: { snapshot in
            Text("Sol will first preserve the current saves, then restore the copy from \(snapshot.createdAt.formatted()). Games must be closed.")
        }
        .alert("Save Vault Needs Attention", isPresented: errorBinding) {
            Button("OK", role: .cancel, action: vault.clearError)
        } message: {
            Text(vault.lastError ?? "Try again.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save Vault")
                    .font(.largeTitle.weight(.semibold))
                Text("Local restore points are included in your private Sol Cloud container.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if vault.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                vault.revealVault()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Button("Create Snapshot", action: vault.createSnapshot)
                .buttonStyle(.borderedProminent)
                .disabled(isGameplayActive || vault.isWorking)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 24)
    }

    private func snapshotRow(_ snapshot: SolSaveSnapshot) -> some View {
        HStack(spacing: 14) {
            Image(systemName: snapshot.reason == .automatic ? "clock.arrow.circlepath" : "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.reason.title)
                    .font(.headline)
                Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(snapshot.fileCount) files · \(snapshot.byteCount, format: .byteCount(style: .file))")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Restore") {
                restoreCandidate = snapshot
            }
            .disabled(isGameplayActive || vault.isWorking)
        }
        .padding(.vertical, 7)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { vault.lastError != nil },
            set: { if !$0 { vault.clearError() } }
        )
    }
}
