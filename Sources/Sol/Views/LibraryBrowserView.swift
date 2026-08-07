import AppKit
import SwiftUI

struct LibraryBrowserView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case recent = "Recent"
        case unplayed = "Unplayed"

        var id: String { rawValue }
    }

    let games: [Game]
    let totalGameCount: Int
    @Binding var selectedGame: Game?
    let thumbnailService: ThumbnailService
    let isScanning: Bool
    let statusMessage: String?
    let canLaunch: Bool
    let onLaunch: (Game) -> Void
    let onRevealGame: (Game) -> Void
    let onRevealMods: (Game) -> Void
    let onRevealSDMods: (Game) -> Void
    let onRevealGameData: (Game) -> Void

    @State private var filter: Filter = .all
    @State private var detailGameID: String?

    var body: some View {
        Group {
            if let detailGame {
                GameDetailView(
                    game: detailGame,
                    thumbnailService: thumbnailService,
                    canLaunch: canLaunch,
                    onBack: { detailGameID = nil },
                    onLaunch: { onLaunch(detailGame) },
                    onRevealGame: { onRevealGame(detailGame) },
                    onRevealMods: { onRevealMods(detailGame) },
                    onRevealSDMods: { onRevealSDMods(detailGame) },
                    onRevealGameData: { onRevealGameData(detailGame) }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                libraryGrid
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.snappy(duration: 0.28), value: detailGameID)
    }

    private var detailGame: Game? {
        guard let detailGameID else { return nil }
        return games.first(where: { $0.id == detailGameID })
    }

    private var filteredGames: [Game] {
        switch filter {
        case .all:
            games
        case .recent:
            games
                .filter { $0.lastPlayed != nil }
                .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .unplayed:
            games.filter { $0.hoursPlayed <= 0 }
        }
    }

    private var libraryGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Library")
                        .font(.title2.weight(.semibold))
                    Text(gameCountLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusMessage ?? "Scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)

            Divider()

            if filteredGames.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "square.grid.2x2")
                } description: {
                    Text(statusMessage ?? emptyDescription)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 150, maximum: 188),
                                spacing: 20,
                                alignment: .top
                            )
                        ],
                        alignment: .leading,
                        spacing: 24
                    ) {
                        ForEach(filteredGames) { game in
                            LibraryGameCard(
                                game: game,
                                isSelected: selectedGame?.id == game.id,
                                thumbnailService: thumbnailService,
                                canLaunch: canLaunch,
                                onOpen: {
                                    selectedGame = game
                                    detailGameID = game.id
                                },
                                onLaunch: {
                                    selectedGame = game
                                    onLaunch(game)
                                },
                                onRevealGame: { onRevealGame(game) },
                                onRevealMods: { onRevealMods(game) },
                                onRevealSDMods: { onRevealSDMods(game) },
                                onRevealGameData: { onRevealGameData(game) }
                            )
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 24)
                    .padding(.bottom, 44)
                }
            }
        }
        .background(.background)
    }

    private var gameCountLabel: String {
        games.count == totalGameCount
            ? "\(totalGameCount) games"
            : "\(games.count) of \(totalGameCount) games"
    }

    private var emptyTitle: String {
        filter == .unplayed ? "Everything Has Been Played" : "No Games Here"
    }

    private var emptyDescription: String {
        filter == .recent
            ? "Played games will appear here."
            : "Choose a games folder in Settings, then refresh the library."
    }
}

private struct LibraryGameCard: View {
    private static let coverAspect: CGFloat = 0.714

    let game: Game
    let isSelected: Bool
    let thumbnailService: ThumbnailService
    let canLaunch: Bool
    let onOpen: () -> Void
    let onLaunch: () -> Void
    let onRevealGame: () -> Void
    let onRevealMods: () -> Void
    let onRevealSDMods: () -> Void
    let onRevealGameData: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: onOpen) {
                    Color.clear
                    .aspectRatio(Self.coverAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        ThumbnailView(
                            game: game,
                            service: thumbnailService,
                            targetSize: CGSize(width: 376, height: 526)
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.14),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                    .shadow(
                        color: .black.opacity(isHovering ? 0.3 : 0.16),
                        radius: isHovering ? 16 : 7,
                        y: isHovering ? 8 : 3
                    )
                }
                .buttonStyle(.plain)

                Button(action: onLaunch) {
                    Image(systemName: "play.fill")
                        .font(.callout.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .disabled(!canLaunch)
                .padding(10)
                .opacity(isHovering || isSelected ? 1 : 0)
                .scaleEffect(isHovering || isSelected ? 1 : 0.84)
                .accessibilityLabel("Play \(game.title)")
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(game.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .frame(height: 38, alignment: .topLeading)

                Text(game.formattedPlaytime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: onLaunch)
                .disabled(!canLaunch)
            Button("View Details", systemImage: "info.circle", action: onOpen)
            Divider()
            Button("Show Game in Finder", systemImage: "folder", action: onRevealGame)
            Button("Open Mods Folder", systemImage: "shippingbox", action: onRevealMods)
            Button("Open SD Card Mods", systemImage: "sdcard", action: onRevealSDMods)
            Button("Open Game Data", systemImage: "internaldrive", action: onRevealGameData)
        }
    }
}

private struct GameDetailView: View {
    let game: Game
    let thumbnailService: ThumbnailService
    let canLaunch: Bool
    let onBack: () -> Void
    let onLaunch: () -> Void
    let onRevealGame: () -> Void
    let onRevealMods: () -> Void
    let onRevealSDMods: () -> Void
    let onRevealGameData: () -> Void

    @State private var backgroundImage: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Button(action: onBack) {
                        Label("Library", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)

                    Text(game.title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()
                }

                hero
                details
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 44)
        }
        .background(.background)
        .task(id: game.id) {
            backgroundImage = await thumbnailService.fetchBackground(for: game)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let backgroundImage {
                    Image(nsImage: backgroundImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    Theme.background
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 330)
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.08), .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            HStack(alignment: .bottom, spacing: 22) {
                ThumbnailView(
                    game: game,
                    service: thumbnailService,
                    targetSize: CGSize(width: 320, height: 448)
                )
                .frame(width: 142, height: 199)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.42), radius: 20, y: 10)

                VStack(alignment: .leading, spacing: 9) {
                    Text(game.title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Label(game.formattedPlaytime, systemImage: "clock")
                        if let lastPlayed = game.formattedLastPlayed {
                            Text("•")
                            Text("Played \(lastPlayed)")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.76))
                }

                Spacer(minLength: 12)

                Button(action: onLaunch) {
                    Label("Play", systemImage: "play.fill")
                        .frame(minWidth: 76)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!canLaunch)

                optionsMenu
                    .menuIndicator(.hidden)
                    .controlSize(.large)
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            detailRow("Title ID", game.titleId ?? "Unavailable")
            detailRow("Format", game.fileURL.pathExtension.uppercased())
            detailRow("File", game.fileURL.lastPathComponent)
            if let fileSize {
                detailRow("Size", fileSize)
            }
            detailRow("Playtime", game.formattedPlaytime)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var fileSize: String? {
        guard let size = try? game.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private var optionsMenu: some View {
        Menu {
            Button("Show Game in Finder", systemImage: "folder", action: onRevealGame)
            Divider()
            Button("Open Mods Folder", systemImage: "shippingbox", action: onRevealMods)
            Button("Open SD Card Mods", systemImage: "sdcard", action: onRevealSDMods)
            Button("Open Game Data", systemImage: "internaldrive", action: onRevealGameData)
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }
}
