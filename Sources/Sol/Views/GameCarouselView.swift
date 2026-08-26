import SwiftUI
import Foundation

struct GameCarouselView: View {
    static let preferredHeight: CGFloat = 340

    let games: [Game]
    let totalGameCount: Int
    @Binding var selectedGame: Game?
    let thumbnailService: ThumbnailService
    @Binding var scrollOffset: CGFloat
    let isGamingMode: Bool
    let isScanning: Bool
    let isLaunching: Bool
    let statusMessage: String?
    let onLaunch: (Game) -> Void
    let onRevealGame: (Game) -> Void
    let onRevealMods: (Game) -> Void
    let onRevealSDMods: (Game) -> Void
    let onRevealGameData: (Game) -> Void

    private let rowHeight: CGFloat = GameCardView.cardSize.height
        + GameCardView.titleHeight
        + GameCardView.verticalSpacing
        + 38
    private let cardSpacing: CGFloat = 14

    @State private var isUserDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            libraryHeader

            if games.isEmpty {
                ContentUnavailableView {
                    Label("No Games Found", systemImage: "square.grid.2x2")
                } description: {
                    Text(statusMessage ?? "Choose a games folder in Settings, then rescan your library.")
                }
                .frame(maxWidth: .infinity, minHeight: rowHeight)
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        let contentWidth = CGFloat(games.count) * GameCardView.cardSize.width
                            + CGFloat(max(games.count - 1, 0)) * cardSpacing
                        let horizontalInset = max(6, (geometry.size.width - contentWidth) * 0.5)

                        ScrollView(.horizontal, showsIndicators: true) {
                            LazyHStack(spacing: cardSpacing) {
                                ForEach(games) { game in
                                    let isSelected = game.id == selectedGame?.id
                                    GameCardView(
                                        game: game,
                                        isSelected: isSelected,
                                        thumbnailService: thumbnailService,
                                        isGamingMode: isGamingMode,
                                        onSelect: {
                                            selectedGame = game
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
                                    .id(game.id)
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.vertical, 14)
                            .padding(.horizontal, horizontalInset)
                            .background(
                                GeometryReader { geo in
                                    let frame = geo.frame(in: .named("carousel"))
                                    Color.clear
                                        .preference(key: ScrollOffsetPreferenceKey.self, value: -frame.minX)
                                }
                            )
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .frame(height: rowHeight)
                        .clipped()
                        .coordinateSpace(name: "carousel")
                        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                            guard abs(value - scrollOffset) >= 1.5 else { return }
                            scrollOffset = value
                        }
                        .onAppear {
                            scrollToSelection(using: proxy, after: 0.15, animated: false)
                        }
                        .onChange(of: selectedGame?.id) { _, newValue in
                            guard let newValue else { return }
                            guard !isUserDragging else { return }
                            scrollToSelection(
                                using: proxy,
                                id: newValue,
                                after: 0.05,
                                animated: true
                            )
                        }
                        .onChange(of: games.count) { _, _ in
                            guard !isUserDragging else { return }
                            scrollToSelection(using: proxy, after: 0.15, animated: false)
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { _ in
                                    isUserDragging = true
                                }
                                .onEnded { _ in
                                    isUserDragging = false
                                }
                        )
                    }
                    .frame(height: rowHeight)
                }
            }
        }
        .padding(14)
        .modifier(NativeLibrarySurface())
        .accessibilityElement(children: .contain)
    }

    private var libraryHeader: some View {
        HStack(spacing: 8) {
            Label("Library", systemImage: "square.grid.2x2")
                .font(.headline)

            Text(
                games.count == totalGameCount
                    ? "\(totalGameCount) Games"
                    : "\(games.count) of \(totalGameCount) Games"
            )
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            Spacer()

            if isScanning {
                ProgressView()
                    .controlSize(.small)

                Text(statusMessage ?? "Scanning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isLaunching {
                ProgressView()
                    .controlSize(.small)

                Text("Launching…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isGamingMode ? 0.55 : 1)
    }

    private func scrollToSelection(
        using proxy: ScrollViewProxy,
        id: String? = nil,
        after delay: TimeInterval,
        animated: Bool
    ) {
        guard let targetID = id ?? selectedGame?.id else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard games.contains(where: { $0.id == targetID }) else { return }

            if animated {
                let animation = isGamingMode
                    ? Animation.interpolatingSpring(stiffness: 280, damping: 32)
                    : Animation.interpolatingSpring(stiffness: 220, damping: 26)
                withAnimation(animation) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            } else {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }
}

private struct NativeLibrarySurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(
                    cornerRadius: SolGeometry.panelCornerRadius,
                    style: .continuous
                )
            )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(
                        cornerRadius: SolGeometry.panelCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: SolGeometry.panelCornerRadius,
                        style: .continuous
                    )
                        .stroke(.separator.opacity(0.45), lineWidth: 1)
                }
        }
    }
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SelectedCardFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}
