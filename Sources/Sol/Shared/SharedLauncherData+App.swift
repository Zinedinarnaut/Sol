import Foundation

extension SharedGameRecord {
    init(game: Game) {
        self.id = game.id
        self.title = game.title
        self.titleId = game.titleId
        self.hoursPlayed = game.hoursPlayed
        self.lastPlayed = game.lastPlayed
        self.thumbnailKey = SharedThumbnailStore.key(titleId: game.titleId, title: game.title)
        self.filePath = game.fileURL.path
    }
}

extension SharedDataStore {
    func updateGamesFromApp(_ games: [Game]) {
        let records = games.map { SharedGameRecord(game: $0) }
        updateGames(records)
    }

    func markLaunchedFromApp(game: Game) {
        let key = SharedThumbnailStore.key(titleId: game.titleId, title: game.title)
        markLaunched(id: game.id, title: game.title, titleId: game.titleId, hoursPlayed: game.hoursPlayed, thumbnailKey: key, filePath: game.fileURL.path)
    }
}
