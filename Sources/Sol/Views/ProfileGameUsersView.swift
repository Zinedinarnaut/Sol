import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileGameUsersView: View {
    @ObservedObject var viewModel: LauncherViewModel

    @State private var isCreating = false
    @State private var editingProfile: SolEngineProfile?
    @State private var deletingProfile: SolEngineProfile?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if viewModel.backendProfiles.isEmpty {
                ContentUnavailableView {
                    Label("No Game Users", systemImage: "person.2.crop.square.stack")
                } description: {
                    Text("Refresh Sol Engine’s user database or create a game user.")
                } actions: {
                    Button("Refresh", action: viewModel.refreshProfiles)
                    Button("Create User") { isCreating = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.backendProfiles) { profile in
                    profileRow(profile)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if viewModel.backendProfiles.isEmpty, !viewModel.isBackendOperationRunning {
                viewModel.refreshProfiles()
            }
        }
        .sheet(isPresented: $isCreating) {
            GameUserNameSheet(title: "Create Game User", initialName: "") { name in
                viewModel.createGameProfile(name: name)
            }
        }
        .sheet(item: $editingProfile) { profile in
            GameUserNameSheet(title: "Rename Game User", initialName: profile.name) { name in
                viewModel.renameGameProfile(profile, name: name)
            }
        }
        .confirmationDialog(
            "Remove this game user?",
            isPresented: Binding(
                get: { deletingProfile != nil },
                set: { if !$0 { deletingProfile = nil } }
            ),
            presenting: deletingProfile
        ) { profile in
            Button("Remove User", role: .destructive) {
                viewModel.deleteGameProfile(profile)
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) {
                deletingProfile = nil
            }
        } message: { profile in
            Text("\(profile.name) will be removed from the user picker. Sol preserves the underlying save files and creates cloud recovery history.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Game Users")
                    .font(.largeTitle.weight(.semibold))
                Text("These are the users games see. The default user opens automatically and owns its saves.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isBackendOperationRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                viewModel.refreshProfiles()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isBackendOperationRunning)

            Button {
                isCreating = true
            } label: {
                Label("Create User", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.backendProfiles.count >= 8 || viewModel.isBackendOperationRunning)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 24)
    }

    private func profileRow(_ profile: SolEngineProfile) -> some View {
        HStack(spacing: 14) {
            gameUserAvatar(profile)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(profile.name)
                        .font(.headline)
                    if profile.isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                .quaternary,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                }
                Text(profile.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            if !profile.isDefault {
                Button("Make Default") {
                    viewModel.selectProfile(profile)
                }
                .disabled(viewModel.isBackendOperationRunning)
            }

            Menu {
                Button("Rename", systemImage: "pencil") {
                    editingProfile = profile
                }
                Button("Choose Picture…", systemImage: "photo") {
                    choosePicture(for: profile)
                }
                Divider()
                Button("Remove User", systemImage: "trash", role: .destructive) {
                    deletingProfile = profile
                }
                .disabled(profile.isDefault || viewModel.backendProfiles.count <= 1)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(viewModel.isBackendOperationRunning)
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func gameUserAvatar(_ profile: SolEngineProfile) -> some View {
        if let data = profile.imageData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
        }
    }

    private func choosePicture(for profile: SolEngineProfile) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Game User Picture"
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.updateGameProfileImage(profile, from: url)
    }
}

private struct GameUserNameSheet: View {
    let title: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("1–32 characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(normalizedName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedName.isEmpty || normalizedName.count > 32)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
