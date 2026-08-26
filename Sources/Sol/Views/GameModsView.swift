import SwiftUI

struct GameModsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case mods = "Mods"
        case cheats = "Cheats"
        var id: String { rawValue }
    }

    let game: Game
    let manager: SolModManager
    let onOpenMods: () -> Void
    let onOpenSDMods: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection = Section.mods
    @State private var inventory = SolModInventory()
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mods & Cheats")
                        .font(.title2.weight(.semibold))
                    Text(game.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            HStack {
                Picker("Content", selection: $selection) {
                    ForEach(Section.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Spacer()

                Menu("Open Folder", systemImage: "folder") {
                    Button("Sol Mods", action: onOpenMods)
                    Button("SD Card Mods", action: onOpenSDMods)
                }

                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            Group {
                if selection == .mods {
                    modsList
                } else {
                    cheatsList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 520)
        .onAppear(perform: reload)
        .alert("Mods Couldn’t Be Updated", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Try again.")
        }
    }

    @ViewBuilder
    private var modsList: some View {
        if inventory.mods.isEmpty {
            ContentUnavailableView {
                Label("No Mods Found", systemImage: "shippingbox")
            } description: {
                Text("Put a mod folder containing romfs or exefs in either content folder, then refresh.")
            }
        } else {
            List(inventory.mods) { mod in
                Toggle(isOn: modBinding(mod)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mod.name)
                            .font(.headline)
                        Text("\(mod.types.joined(separator: " + ")) · \(mod.source.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.vertical, 5)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var cheatsList: some View {
        if inventory.cheats.isEmpty {
            ContentUnavailableView {
                Label("No Cheats Found", systemImage: "terminal")
            } description: {
                Text("Atmosphere-format cheat sections from the title’s cheats folders will appear here.")
            }
        } else {
            VStack(spacing: 0) {
                Label(
                    "Cheats can alter game state and save data. Keep a Save Vault snapshot before enabling unfamiliar codes.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                List(inventory.cheats) { cheat in
                    Toggle(isOn: cheatBinding(cheat)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cheat.name)
                                .font(.headline)
                            Text("\(cheat.fileName) · \(cheat.source.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
    }

    private func reload() {
        guard let titleID = game.titleId else {
            errorMessage = "This game does not have a title ID."
            return
        }
        do {
            inventory = try manager.load(titleID: titleID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func modBinding(_ item: SolModItem) -> Binding<Bool> {
        Binding(
            get: { inventory.mods.first(where: { $0.id == item.id })?.isEnabled ?? item.isEnabled },
            set: { enabled in
                guard let titleID = game.titleId else { return }
                do {
                    inventory = try manager.setModEnabled(
                        enabled,
                        item: item,
                        titleID: titleID
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private func cheatBinding(_ item: SolCheatItem) -> Binding<Bool> {
        Binding(
            get: { inventory.cheats.first(where: { $0.id == item.id })?.isEnabled ?? item.isEnabled },
            set: { enabled in
                guard let titleID = game.titleId else { return }
                do {
                    inventory = try manager.setCheatEnabled(
                        enabled,
                        item: item,
                        titleID: titleID
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
