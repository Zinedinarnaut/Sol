import WidgetKit
import SwiftUI

struct TopPlayedEntry: TimelineEntry {
    let date: Date
    let games: [SharedGameRecord]
    let images: [String: Image]
}

struct TopPlayedProvider: TimelineProvider {
    private let loader = WidgetDataLoader()

    func placeholder(in context: Context) -> TopPlayedEntry {
        TopPlayedEntry(date: Date(), games: [], images: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (TopPlayedEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TopPlayedEntry>) -> Void) {
        let entry = makeEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func makeEntry() -> TopPlayedEntry {
        let snapshot = loader.loadSnapshot()
        let games = loader.topPlayed(from: snapshot, limit: 3)
        var images: [String: Image] = [:]
        for game in games {
            if let image = loader.image(for: game.thumbnailKey) {
                images[game.id] = image
            }
        }
        return TopPlayedEntry(date: Date(), games: games, images: images)
    }
}

struct TopPlayedWidgetView: View {
    let entry: TopPlayedEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Played")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WidgetTheme.textMuted)

            if entry.games.isEmpty {
                Text("No playtime data")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(entry.games.prefix(3).enumerated()), id: \.element.id) { index, game in
                        let isPrimary = index == 0
                        VStack(alignment: .leading, spacing: 6) {
                            WidgetGameCard(
                                image: entry.images[game.id],
                                size: WidgetGameCard.posterSize(height: isPrimary ? 118 : 100),
                                emphasis: isPrimary ? 1.0 : 0.78
                            )

                            Text(game.title)
                                .font(.system(size: isPrimary ? 10 : 9, weight: .semibold))
                                .foregroundStyle(WidgetTheme.textPrimary.opacity(isPrimary ? 1.0 : 0.8))
                                .lineLimit(isPrimary ? 2 : 1)

                            Text(String(format: "%.1f hrs", game.hoursPlayed))
                                .font(.system(size: isPrimary ? 9 : 8, weight: .medium))
                                .foregroundStyle(WidgetTheme.textSecondary.opacity(isPrimary ? 1.0 : 0.75))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .containerBackground(for: .widget) {
            WidgetTheme.background
        }
    }
}

struct TopPlayedWidget: Widget {
    let kind = "TopPlayedWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TopPlayedProvider()) { entry in
            TopPlayedWidgetView(entry: entry)
        }
        .supportedFamilies([.systemMedium])
        .configurationDisplayName("Top Played")
        .description("Shows your top played games.")
    }
}
