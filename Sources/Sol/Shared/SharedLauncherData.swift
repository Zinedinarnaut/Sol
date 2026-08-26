import Foundation
import CryptoKit

#if canImport(WidgetKit)
import WidgetKit
#endif

struct SharedGameRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let titleId: String?
    let hoursPlayed: Double
    let lastPlayed: Date?
    let thumbnailKey: String
    let filePath: String?
}

struct SharedLauncherSnapshot: Codable, Hashable, Sendable {
    var games: [SharedGameRecord]
    var lastLaunchedId: String?
    var lastLaunchedAt: Date?
    var pendingLaunchId: String?
    var pendingLaunchPath: String?
    var pendingLaunchRequestedAt: Date? = nil
    var solEngineValid: Bool?
    var gamesValid: Bool?
}

enum SharedPendingLaunchTarget: Hashable, Sendable {
    case id(String)
    case path(String)
}

struct SharedPendingLaunchRequest: Hashable, Sendable {
    static let maximumAge: TimeInterval = 120

    let target: SharedPendingLaunchTarget
    let requestedAt: Date

    init?(id: String, requestedAt: Date = Date()) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }
        target = .id(normalizedID)
        self.requestedAt = requestedAt
    }

    init?(path: String, requestedAt: Date = Date()) {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        target = .path(Self.normalizedPath(path))
        self.requestedAt = requestedAt
    }

    init?(url: URL, requestedAt: Date = Date()) {
        if url.isFileURL {
            self.init(path: url.path, requestedAt: requestedAt)
            return
        }

        guard url.scheme?.lowercased() == "sol",
              url.host?.lowercased() == "launch",
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }

        let query = components.queryItems ?? []
        if let id = query.first(where: { $0.name == "id" })?.value,
           let request = Self(id: id, requestedAt: requestedAt) {
            self = request
        } else if let path = query.first(where: { $0.name == "path" })?.value,
                  let request = Self(path: path, requestedAt: requestedAt) {
            self = request
        } else {
            return nil
        }
    }

    var id: String? {
        guard case .id(let id) = target else { return nil }
        return id
    }

    var path: String? {
        guard case .path(let path) = target else { return nil }
        return path
    }

    func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(requestedAt)
        return age >= 0 && age <= Self.maximumAge
    }

    func duplicates(
        _ earlierRequest: SharedPendingLaunchRequest,
        within interval: TimeInterval
    ) -> Bool {
        guard target == earlierRequest.target else { return false }
        let elapsed = requestedAt.timeIntervalSince(earlierRequest.requestedAt)
        return elapsed >= 0 && elapsed <= interval
    }

    fileprivate static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

final class SharedDataStore: @unchecked Sendable {
    static let appGroupID = "group.com.solemu.app"
    static let shared = SharedDataStore()

    private let queue = DispatchQueue(label: "solEngine.shared.data", qos: .utility)
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func updateGames(_ games: [SharedGameRecord]) {
        queue.async {
            var snapshot = self.loadSnapshotInternal() ?? SharedLauncherSnapshot(games: [], lastLaunchedId: nil, lastLaunchedAt: nil, pendingLaunchId: nil, pendingLaunchPath: nil, solEngineValid: nil, gamesValid: nil)
            let existingById = Dictionary(uniqueKeysWithValues: snapshot.games.map { ($0.id, $0) })

            let newRecords: [SharedGameRecord] = games.map { game in
                let existing = existingById[game.id]
                return SharedGameRecord(
                    id: game.id,
                    title: game.title,
                    titleId: game.titleId,
                    hoursPlayed: game.hoursPlayed,
                    lastPlayed: existing?.lastPlayed ?? game.lastPlayed,
                    thumbnailKey: game.thumbnailKey,
                    filePath: game.filePath ?? existing?.filePath
                )
            }

            snapshot.games = newRecords
            self.saveSnapshotInternal(snapshot)
        }
    }

    func markLaunched(id: String, title: String, titleId: String?, hoursPlayed: Double, thumbnailKey: String, filePath: String?) {
        queue.async {
            var snapshot = self.loadSnapshotInternal() ?? SharedLauncherSnapshot(games: [], lastLaunchedId: nil, lastLaunchedAt: nil, pendingLaunchId: nil, pendingLaunchPath: nil, solEngineValid: nil, gamesValid: nil)
            let now = Date()
            snapshot.lastLaunchedId = id
            snapshot.lastLaunchedAt = now

            var updated: [SharedGameRecord] = []
            var found = false
            for record in snapshot.games {
                if record.id == id {
                    updated.append(SharedGameRecord(
                        id: record.id,
                        title: title,
                        titleId: titleId,
                        hoursPlayed: hoursPlayed,
                        lastPlayed: now,
                        thumbnailKey: thumbnailKey,
                        filePath: filePath ?? record.filePath
                    ))
                    found = true
                } else {
                    updated.append(record)
                }
            }

            if !found {
                updated.append(SharedGameRecord(
                    id: id,
                    title: title,
                    titleId: titleId,
                    hoursPlayed: hoursPlayed,
                    lastPlayed: now,
                    thumbnailKey: thumbnailKey,
                    filePath: filePath
                ))
            }

            snapshot.games = updated
            self.saveSnapshotInternal(snapshot)
        }
    }

    func setPendingLaunch(
        id: String,
        requestedAt: Date = Date(),
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard let request = SharedPendingLaunchRequest(
            id: id,
            requestedAt: requestedAt
        ) else {
            completion?()
            return
        }
        setPendingLaunch(request, completion: completion)
    }

    func setPendingLaunch(
        path: String,
        requestedAt: Date = Date(),
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard let request = SharedPendingLaunchRequest(
            path: path,
            requestedAt: requestedAt
        ) else {
            completion?()
            return
        }
        setPendingLaunch(request, completion: completion)
    }

    func setPendingLaunch(
        _ request: SharedPendingLaunchRequest,
        completion: (@Sendable () -> Void)? = nil
    ) {
        queue.async {
            var snapshot = self.loadSnapshotInternal() ?? SharedLauncherSnapshot(games: [], lastLaunchedId: nil, lastLaunchedAt: nil, pendingLaunchId: nil, pendingLaunchPath: nil, solEngineValid: nil, gamesValid: nil)
            switch request.target {
            case .id(let id):
                snapshot.pendingLaunchId = id
                snapshot.pendingLaunchPath = nil
            case .path(let path):
                snapshot.pendingLaunchPath = path
                snapshot.pendingLaunchId = nil
            }
            snapshot.pendingLaunchRequestedAt = request.requestedAt
            self.saveSnapshotInternal(snapshot)
            completion?()
        }
    }

    func consumePendingLaunch(
        completion: @Sendable @escaping (_ id: String?, _ path: String?) -> Void
    ) {
        queue.async {
            guard var snapshot = self.loadSnapshotInternal() else {
                completion(nil, nil)
                return
            }
            let originalSnapshot = snapshot
            let request = Self.takePendingLaunchIfReady(from: &snapshot)
            if snapshot != originalSnapshot {
                self.saveSnapshotInternal(snapshot)
            }
            completion(request?.id, request?.path)
        }
    }

    static func isPendingLaunchFresh(requestedAt: Date?, now: Date = Date()) -> Bool {
        guard let requestedAt else { return false }
        let age = now.timeIntervalSince(requestedAt)
        return age >= 0 && age <= SharedPendingLaunchRequest.maximumAge
    }

    static func takePendingLaunchIfReady(
        from snapshot: inout SharedLauncherSnapshot,
        now: Date = Date(),
        fileExists: (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) -> SharedPendingLaunchRequest? {
        let request: SharedPendingLaunchRequest?
        if let id = snapshot.pendingLaunchId,
           let requestedAt = snapshot.pendingLaunchRequestedAt {
            request = SharedPendingLaunchRequest(id: id, requestedAt: requestedAt)
        } else if let path = snapshot.pendingLaunchPath,
                  let requestedAt = snapshot.pendingLaunchRequestedAt {
            request = SharedPendingLaunchRequest(path: path, requestedAt: requestedAt)
        } else {
            request = nil
        }

        guard let request else {
            clearPendingLaunch(in: &snapshot)
            return nil
        }
        guard request.isFresh(at: now) else {
            clearPendingLaunch(in: &snapshot)
            return nil
        }
        guard isPendingLaunchReady(
            request,
            snapshot: snapshot,
            fileExists: fileExists
        ) else {
            return nil
        }

        clearPendingLaunch(in: &snapshot)
        return request
    }

    private static func isPendingLaunchReady(
        _ request: SharedPendingLaunchRequest,
        snapshot: SharedLauncherSnapshot,
        fileExists: (String) -> Bool
    ) -> Bool {
        guard snapshot.solEngineValid == true else { return false }

        switch request.target {
        case .id(let id):
            return snapshot.gamesValid == true && snapshot.games.contains {
                $0.id == id
            }
        case .path(let path):
            let matchesLibrary = snapshot.games.contains { game in
                guard let filePath = game.filePath else { return false }
                return SharedPendingLaunchRequest.normalizedPath(filePath) == path
            }
            return matchesLibrary ? snapshot.gamesValid == true : fileExists(path)
        }
    }

    private static func clearPendingLaunch(
        in snapshot: inout SharedLauncherSnapshot
    ) {
        snapshot.pendingLaunchId = nil
        snapshot.pendingLaunchPath = nil
        snapshot.pendingLaunchRequestedAt = nil
    }

    func updateValidation(solEngineValid: Bool, gamesValid: Bool) {
        queue.async {
            var snapshot = self.loadSnapshotInternal() ?? SharedLauncherSnapshot(games: [], lastLaunchedId: nil, lastLaunchedAt: nil, pendingLaunchId: nil, pendingLaunchPath: nil, solEngineValid: nil, gamesValid: nil)
            snapshot.solEngineValid = solEngineValid
            snapshot.gamesValid = gamesValid
            self.saveSnapshotInternal(snapshot)
        }
    }

    func loadSnapshot(completion: @Sendable @escaping (SharedLauncherSnapshot?) -> Void) {
        queue.async {
            completion(self.loadSnapshotInternal())
        }
    }

    func loadSnapshotSync() -> SharedLauncherSnapshot? {
        queue.sync {
            loadSnapshotInternal()
        }
    }

    private func loadSnapshotInternal() -> SharedLauncherSnapshot? {
        guard let url = dataURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SharedLauncherSnapshot.self, from: data)
    }

    private func saveSnapshotInternal(_ snapshot: SharedLauncherSnapshot) {
        guard let url = dataURL() else { return }
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            reloadWidgets()
        } catch {
            return
        }
    }

    private func dataURL() -> URL? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            return nil
        }
        return container.appendingPathComponent("sol_snapshot.json")
    }

    private func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

final class SharedThumbnailStore: @unchecked Sendable {
    static let shared = SharedThumbnailStore()

    private let fileManager = FileManager.default
    private let lock = NSLock()

    private init() {}

    static func key(titleId: String?, title: String) -> String {
        return titleId ?? title
    }

    func store(data: Data, key: String, fileExtension: String) {
        synchronized {
            guard let dir = directoryURL() else { return }
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let filename = Self.hash(key)
            let safeExtension = Self.sanitizedExtension(fileExtension)
            for ext in Self.supportedExtensions where ext != safeExtension {
                let staleURL = dir.appendingPathComponent(filename).appendingPathExtension(ext)
                try? fileManager.removeItem(at: staleURL)
            }
            let url = dir.appendingPathComponent(filename).appendingPathExtension(safeExtension)
            try? data.write(to: url, options: .atomic)
        }
    }

    func imageData(for key: String) -> Data? {
        synchronized {
            guard let dir = directoryURL() else { return nil }
            let filename = Self.hash(key)
            for ext in Self.supportedExtensions {
                let url = dir.appendingPathComponent(filename).appendingPathExtension(ext)
                if let data = try? Data(contentsOf: url) { return data }
            }
            return nil
        }
    }

    func clearAll() {
        synchronized {
            guard let dir = directoryURL() else { return }
            do {
                if fileManager.fileExists(atPath: dir.path) {
                    try fileManager.removeItem(at: dir)
                }
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return
            }
        }
    }

    private func directoryURL() -> URL? {
        // XCTest processes are not signed with Sol's application-group entitlement.
        // Keep their thumbnail writes isolated from the user's real shared container;
        // asking Foundation to atomically write there can stall while macOS retries
        // unavailable container services.
        if ProcessInfo.processInfo.processName == "xctest" {
            return fileManager.temporaryDirectory
                .appendingPathComponent("SolTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("thumbnails", isDirectory: true)
        }

        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedDataStore.appGroupID) else {
            return nil
        }
        return container.appendingPathComponent("thumbnails", isDirectory: true)
    }

    private static func hash(_ value: String) -> String {
        let data = Data(value.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func synchronized<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private static let supportedExtensions = ["jpg", "png", "webp"]

    private static func sanitizedExtension(_ value: String) -> String {
        let normalized = value.lowercased()
        return supportedExtensions.contains(normalized) ? normalized : "jpg"
    }
}
