import SwiftUI
import Foundation

struct GameCarouselView: View {
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
    @State private var cardCenters: [String: CGFloat] = [:]
    @State private var carouselCenterX: CGFloat = 0
    @State private var snapWorkItem: DispatchWorkItem?

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
                                    .background(
                                        GeometryReader { proxy in
                                            let cardFrame = proxy.frame(in: .named("carousel"))
                                            Color.clear
                                                .preference(
                                                    key: CardCenterPreferenceKey.self,
                                                    value: [game.id: cardFrame.midX]
                                                )
                                        }
                                    )
                                    .id(game.id)
                                }
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, horizontalInset)
                            .background(
                                GeometryReader { geo in
                                    let frame = geo.frame(in: .named("carousel"))
                                    Color.clear
                                        .preference(key: ScrollOffsetPreferenceKey.self, value: -frame.minX)
                                        .preference(key: CarouselCenterPreferenceKey.self, value: frame.midX)
                                }
                            )
                        }
                        .scrollClipDisabled()
                        .frame(height: rowHeight)
                        .coordinateSpace(name: "carousel")
                        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                            scrollOffset = value
                        }
                        .onPreferenceChange(CardCenterPreferenceKey.self) { value in
                            cardCenters = value
                        }
                        .onPreferenceChange(CarouselCenterPreferenceKey.self) { value in
                            carouselCenterX = value
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
                                    scheduleSnap(using: proxy)
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

    private func snapToNearest(using proxy: ScrollViewProxy) {
        guard !games.isEmpty, !cardCenters.isEmpty else { return }
        let nearest = cardCenters.min { lhs, rhs in
            abs(lhs.value - carouselCenterX) < abs(rhs.value - carouselCenterX)
        }
        guard let id = nearest?.key,
              let game = games.first(where: { $0.id == id }) else { return }
        if selectedGame?.id != id {
            selectedGame = game
        }
        let animation = isGamingMode
            ? Animation.interpolatingSpring(stiffness: 260, damping: 30)
            : Animation.interpolatingSpring(stiffness: 210, damping: 24)
        withAnimation(animation) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func scheduleSnap(using proxy: ScrollViewProxy) {
        snapWorkItem?.cancel()
        let work = DispatchWorkItem {
            snapToNearest(using: proxy)
        }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
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

private struct CardCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct CarouselCenterPreferenceKey: PreferenceKey {
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
