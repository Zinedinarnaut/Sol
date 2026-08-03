import Foundation
import AppIntents

struct OpenLauncherIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sol"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct LaunchLastPlayedIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch Last Played"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        if let snapshot = SharedDataStore.shared.loadSnapshotSync(),
           let game = snapshot.games.sorted(by: { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }).first,
           snapshot.solEngineValid == true,
           snapshot.gamesValid == true {
            SharedDataStore.shared.setPendingLaunch(id: game.id)
        }
        return .result()
    }
}

struct LauncherGameEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Game")
    static let defaultQuery = LauncherGameQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct LauncherGameQuery: EntityQuery {
    func entities(for identifiers: [LauncherGameEntity.ID]) async throws -> [LauncherGameEntity] {
        guard let snapshot = SharedDataStore.shared.loadSnapshotSync() else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: snapshot.games.map { ($0.id, $0.title) })
        return identifiers.compactMap { id in
            guard let title = lookup[id] else { return nil }
            return LauncherGameEntity(id: id, title: title)
        }
    }

    func suggestedEntities() async throws -> [LauncherGameEntity] {
        guard let snapshot = SharedDataStore.shared.loadSnapshotSync() else { return [] }
        return snapshot.games.map { LauncherGameEntity(id: $0.id, title: $0.title) }
    }
}

struct LaunchGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch Game"
    static let openAppWhenRun = true

    @Parameter(title: "Game")
    var game: LauncherGameEntity

    func perform() async throws -> some IntentResult {
        SharedDataStore.shared.setPendingLaunch(id: game.id)
        return .result()
    }
}

struct SolAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLauncherIntent(),
            phrases: ["Open \(.applicationName)", "Show \(.applicationName)"],
            shortTitle: "Open Sol",
            systemImageName: "gamecontroller"
        )
        AppShortcut(
            intent: LaunchLastPlayedIntent(),
            phrases: ["Launch last played in \(.applicationName)", "Play last game in \(.applicationName)"],
            shortTitle: "Play Last Game",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: LaunchGameIntent(),
            phrases: ["Launch game in \(.applicationName)", "Play game in \(.applicationName)"],
            shortTitle: "Play Game",
            systemImageName: "play.circle.fill"
        )
    }
}
