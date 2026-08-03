import SwiftUI

struct GameCardView: View {
    static let cardSize = CGSize(width: 124, height: 174)
    static let titleHeight: CGFloat = 38
    static let verticalSpacing: CGFloat = 6

    let game: Game
    let isSelected: Bool
    let thumbnailService: ThumbnailService
    let isGamingMode: Bool
    let onSelect: () -> Void
    let onLaunch: () -> Void
    let onRevealGame: () -> Void
    let onRevealMods: () -> Void
    let onRevealSDMods: () -> Void
    let onRevealGameData: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            SoundPlayer.shared.play(.select)
            onSelect()
        } label: {
            cardLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(game.title)
        .accessibilityValue(
            isSelected
                ? "Selected, \(game.formattedPlaytime)"
                : game.formattedPlaytime
        )
        .scaleEffect(cardScale)
        .zIndex(isSelected ? 2 : 1)
        .animation(.interpolatingSpring(stiffness: 240, damping: 28), value: isSelected)
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onLaunch()
            }
        )
        .onHover { hovering in
            isHovering = hovering && !isGamingMode
        }
        .help("\(game.title)\n\(game.formattedPlaytime)")
        .contextMenu {
            Button("Launch", systemImage: "play.fill", action: onLaunch)

            Divider()

            Button("Show Game in Finder", systemImage: "folder", action: onRevealGame)
            Button("Open Mods Folder", systemImage: "shippingbox", action: onRevealMods)
            Button("Open SD Card Mods", systemImage: "sdcard", action: onRevealSDMods)
            Button("Open Game Data", systemImage: "internaldrive", action: onRevealGameData)
        }
    }

    private var cardScale: CGFloat {
        isSelected ? 1 : (isHovering ? 0.99 : 0.97)
    }

    private var cardStrokeColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.9)
        }
        return Color.primary.opacity(isHovering ? 0.18 : 0)
    }

    private var cardLabel: some View {
        VStack(alignment: .leading, spacing: Self.verticalSpacing) {
            cover
            details
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(cardStrokeColor, lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var cover: some View {
        ThumbnailView(game: game, service: thumbnailService, targetSize: Self.cardSize)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        Color.primary.opacity(isSelected ? 0.3 : 0.14),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: .black.opacity(isSelected ? 0.3 : 0.16),
                radius: isSelected ? 8 : 3,
                y: isSelected ? 4 : 2
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SelectedCardFramePreferenceKey.self,
                        value: isSelected ? proxy.frame(in: .named("solRoot")) : .zero
                    )
                }
            )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(game.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(game.formattedPlaytime)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(
            width: Self.cardSize.width,
            height: Self.titleHeight,
            alignment: .topLeading
        )
    }
}
