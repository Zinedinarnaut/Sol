import WidgetKit
import SwiftUI

struct RecentlyPlayedEntry: TimelineEntry {
    let date: Date
    let game: SharedGameRecord?
    let image: Image?
}

struct RecentlyPlayedProvider: TimelineProvider {
    private let loader = WidgetDataLoader()

    func placeholder(in context: Context) -> RecentlyPlayedEntry {
        RecentlyPlayedEntry(date: Date(), game: nil, image: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentlyPlayedEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentlyPlayedEntry>) -> Void) {
        let entry = makeEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 20, to: Date()) ?? Date().addingTimeInterval(1200)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func makeEntry() -> RecentlyPlayedEntry {
        let snapshot = loader.loadSnapshot()
        let game = loader.recentGame(from: snapshot)
        let image = game.flatMap { loader.image(for: $0.thumbnailKey) }
        return RecentlyPlayedEntry(date: Date(), game: game, image: image)
    }
}

struct RecentlyPlayedWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: RecentlyPlayedEntry

    var body: some View {
        content
            .padding(12)
            .containerBackground(for: .widget) {
                WidgetTheme.background
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                WidgetGameCard(
                    image: entry.image,
                    size: WidgetGameCard.posterSize(height: 96),
                    emphasis: 1.0
                )

                Text(entry.game?.title ?? "No recent game")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetTheme.textPrimary)
                    .lineLimit(2)

                Text(entry.game.map { String(format: "%.1f hrs", $0.hoursPlayed) } ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WidgetTheme.textSecondary)
            }
        default:
            HStack(spacing: 12) {
                WidgetGameCard(
                    image: entry.image,
                    size: WidgetGameCard.posterSize(height: 110),
                    emphasis: 1.0
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Recently Played")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WidgetTheme.textMuted)

                    Text(entry.game?.title ?? "No recent game")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WidgetTheme.textPrimary)
                        .lineLimit(2)

                    Text(entry.game.map { String(format: "%.1f hrs", $0.hoursPlayed) } ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WidgetTheme.textSecondary)
                }
                Spacer()
            }
        }
    }
}

struct RecentlyPlayedWidget: Widget {
    let kind = "RecentlyPlayedWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentlyPlayedProvider()) { entry in
            RecentlyPlayedWidgetView(entry: entry)
        }
        .supportedFamilies([.systemSmall, .systemMedium])
        .configurationDisplayName("Recently Played")
        .description("Shows your most recently launched game.")
    }
}
