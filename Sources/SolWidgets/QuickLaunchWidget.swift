import WidgetKit
import SwiftUI
import AppIntents

struct QuickLaunchEntry: TimelineEntry {
    let date: Date
    let game: SharedGameRecord?
    let image: Image?
}

struct QuickLaunchProvider: TimelineProvider {
    private let loader = WidgetDataLoader()

    func placeholder(in context: Context) -> QuickLaunchEntry {
        QuickLaunchEntry(date: Date(), game: nil, image: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickLaunchEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickLaunchEntry>) -> Void) {
        let entry = makeEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func makeEntry() -> QuickLaunchEntry {
        let snapshot = loader.loadSnapshot()
        let game = loader.recentGame(from: snapshot)
        let image = game.flatMap { loader.image(for: $0.thumbnailKey) }
        return QuickLaunchEntry(date: Date(), game: game, image: image)
    }
}

struct LaunchLastPlayedGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch Last Played"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let loader = WidgetDataLoader()
        if let snapshot = loader.loadSnapshot(),
           let game = loader.recentGame(from: snapshot),
           !game.id.isEmpty,
           snapshot.solEngineValid == true,
           snapshot.gamesValid == true {
            SharedDataStore.shared.setPendingLaunch(id: game.id)
        }
        return .result()
    }
}

struct QuickLaunchWidgetView: View {
    let entry: QuickLaunchEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Launch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WidgetTheme.textMuted)

            HStack(spacing: 12) {
                WidgetGameCard(
                    image: entry.image,
                    size: WidgetGameCard.posterSize(height: 100),
                    emphasis: 1.0
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.game?.title ?? "No recent game")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetTheme.textPrimary)
                        .lineLimit(2)

                    Text(entry.game.map { String(format: "%.1f hrs", $0.hoursPlayed) } ?? "")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(WidgetTheme.textSecondary)
                }
                Spacer()
            }

            Button(intent: LaunchLastPlayedGameIntent()) {
                Text("Launch")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(WidgetTheme.panel)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .containerBackground(for: .widget) {
            WidgetTheme.background
        }
    }
}

struct QuickLaunchWidget: Widget {
    let kind = "QuickLaunchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickLaunchProvider()) { entry in
            QuickLaunchWidgetView(entry: entry)
        }
        .supportedFamilies([.systemSmall, .systemMedium])
        .configurationDisplayName("Quick Launch")
        .description("Launch your last played game.")
    }
}
