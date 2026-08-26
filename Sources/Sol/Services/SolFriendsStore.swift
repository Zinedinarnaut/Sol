import Combine
import Foundation

enum SolFriendsStoreError: LocalizedError, Equatable {
    case emptyDisplayName
    case duplicateFriend
    case friendNotFound
    case requestNotFound

    var errorDescription: String? {
        switch self {
        case .emptyDisplayName:
            return "Enter a display name."
        case .duplicateFriend:
            return "That person is already in your Friends list."
        case .friendNotFound:
            return "That friend is no longer available."
        case .requestNotFound:
            return "That request is no longer available."
        }
    }
}

@MainActor
final class SolFriendsStore: ObservableObject {
    @Published private(set) var snapshot: SolFriendsSnapshot
    @Published private(set) var lastError: String?

    let storageURL: URL
    var onPersistedChange: (() -> Void)?

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if let data = try? Data(contentsOf: self.storageURL),
           let stored = try? decoder.decode(SolFriendsSnapshot.self, from: data),
           stored.schemaVersion == 1 {
            snapshot = stored
        } else {
            snapshot = .empty()
        }
    }

    var identity: SolSocialIdentity { snapshot.identity }
    var friends: [SolFriend] { snapshot.friends }
    var requests: [SolFriendRequest] { snapshot.requests }
    var recentPlayers: [SolRecentPlayer] { snapshot.recentPlayers }

    func prepareIdentity(defaultDisplayName: String) {
        let name = sanitized(defaultDisplayName)
        guard !name.isEmpty,
              snapshot.identity.displayName == "Sol Player"
                || snapshot.identity.displayName == "RyuPlayer" else {
            return
        }

        try? update { snapshot in
            snapshot.identity.displayName = name
        }
    }

    /// Makes the active game user the identity shown throughout Sol. This
    /// keeps Home, Profile, Friends, multiplayer, and toolbar chrome aligned
    /// with the user that games and save data currently use.
    func synchronizeActiveGameUser(displayName: String) {
        let name = sanitized(displayName)
        guard !name.isEmpty,
              name.compare(
                "RyuPlayer",
                options: [.caseInsensitive, .diacriticInsensitive]
              ) != .orderedSame,
              snapshot.identity.displayName != name
                || snapshot.identity.avatarSource != .gameProfile else {
            return
        }

        try? update { snapshot in
            snapshot.identity.displayName = name
            snapshot.identity.avatarSource = .gameProfile
        }
    }

    func updateIdentity(
        displayName: String,
        statusMessage: String,
        allowsFriendRequests: Bool,
        sharesPlayActivity: Bool,
        appearsInRecentPlayers: Bool
    ) throws {
        try updateIdentity(
            displayName: displayName,
            statusMessage: statusMessage,
            allowsFriendRequests: allowsFriendRequests,
            sharesPlayActivity: sharesPlayActivity,
            appearsInRecentPlayers: appearsInRecentPlayers,
            avatarSource: snapshot.identity.avatarSource,
            pixelAvatar: snapshot.identity.pixelAvatar,
            customAvatarRevision: snapshot.identity.customAvatarRevision
        )
    }

    func updateIdentity(
        displayName: String,
        statusMessage: String,
        allowsFriendRequests: Bool,
        sharesPlayActivity: Bool,
        appearsInRecentPlayers: Bool,
        avatarSource: SolProfileAvatarSource?,
        pixelAvatar: SolPixelAvatar?,
        customAvatarRevision: UUID? = nil
    ) throws {
        let name = sanitized(displayName)
        guard !name.isEmpty else {
            throw SolFriendsStoreError.emptyDisplayName
        }

        try update { snapshot in
            snapshot.identity.displayName = name
            snapshot.identity.statusMessage = sanitized(statusMessage)
            snapshot.identity.allowsFriendRequests = allowsFriendRequests
            snapshot.identity.sharesPlayActivity = sharesPlayActivity
            snapshot.identity.appearsInRecentPlayers = appearsInRecentPlayers
            snapshot.identity.avatarSource = avatarSource
            snapshot.identity.pixelAvatar = pixelAvatar
            snapshot.identity.customAvatarRevision = customAvatarRevision
        }
    }

    func setAllowsFriendRequests(_ value: Bool) {
        try? update { $0.identity.allowsFriendRequests = value }
    }

    func setSharesPlayActivity(_ value: Bool) {
        try? update { $0.identity.sharesPlayActivity = value }
    }

    func setAppearsInRecentPlayers(_ value: Bool) {
        try? update { $0.identity.appearsInRecentPlayers = value }
    }

    @discardableResult
    func addLocalFriend(displayName: String, note: String = "") throws -> SolFriend {
        let name = sanitized(displayName)
        guard !name.isEmpty else {
            throw SolFriendsStoreError.emptyDisplayName
        }
        guard !snapshot.friends.contains(where: {
            $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            throw SolFriendsStoreError.duplicateFriend
        }

        let friend = SolFriend(
            id: UUID(),
            displayName: name,
            note: sanitized(note),
            presence: .offline,
            lastSeen: nil,
            lastActivity: nil,
            isFavorite: false,
            addedAt: Date()
        )
        try update { snapshot in
            snapshot.friends.append(friend)
            snapshot.friends.sort(by: Self.friendSort)
        }
        return friend
    }

    func removeFriend(id: UUID) throws {
        guard snapshot.friends.contains(where: { $0.id == id }) else {
            throw SolFriendsStoreError.friendNotFound
        }
        try update { snapshot in
            snapshot.friends.removeAll { $0.id == id }
        }
    }

    func setFavorite(_ isFavorite: Bool, friendID: UUID) throws {
        guard let index = snapshot.friends.firstIndex(where: { $0.id == friendID }) else {
            throw SolFriendsStoreError.friendNotFound
        }
        try update { snapshot in
            snapshot.friends[index].isFavorite = isFavorite
            snapshot.friends.sort(by: Self.friendSort)
        }
    }

    func recordIncomingRequest(displayName: String, message: String? = nil) throws {
        let name = sanitized(displayName)
        guard !name.isEmpty else {
            throw SolFriendsStoreError.emptyDisplayName
        }
        guard !snapshot.friends.contains(where: {
            $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            throw SolFriendsStoreError.duplicateFriend
        }

        let request = SolFriendRequest(
            id: UUID(),
            displayName: name,
            message: message.flatMap { sanitized($0).isEmpty ? nil : sanitized($0) },
            receivedAt: Date()
        )
        try update { $0.requests.append(request) }
    }

    func acceptRequest(id: UUID) throws {
        guard let request = snapshot.requests.first(where: { $0.id == id }) else {
            throw SolFriendsStoreError.requestNotFound
        }
        guard !snapshot.friends.contains(where: {
            $0.displayName.compare(
                request.displayName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) else {
            try declineRequest(id: id)
            throw SolFriendsStoreError.duplicateFriend
        }

        let friend = SolFriend(
            id: UUID(),
            displayName: request.displayName,
            note: "",
            presence: .offline,
            lastSeen: nil,
            lastActivity: nil,
            isFavorite: false,
            addedAt: Date()
        )
        try update { snapshot in
            snapshot.requests.removeAll { $0.id == id }
            snapshot.friends.append(friend)
            snapshot.friends.sort(by: Self.friendSort)
        }
    }

    func declineRequest(id: UUID) throws {
        guard snapshot.requests.contains(where: { $0.id == id }) else {
            throw SolFriendsStoreError.requestNotFound
        }
        try update { $0.requests.removeAll { $0.id == id } }
    }

    func recordRecentPlayer(
        id: UUID,
        displayName: String,
        activity: String?,
        encounteredAt: Date = Date()
    ) throws {
        let name = sanitized(displayName)
        guard !name.isEmpty else {
            throw SolFriendsStoreError.emptyDisplayName
        }

        let player = SolRecentPlayer(
            id: id,
            displayName: name,
            activity: activity.flatMap { sanitized($0).isEmpty ? nil : sanitized($0) },
            encounteredAt: encounteredAt
        )
        try update { snapshot in
            snapshot.recentPlayers.removeAll { $0.id == id }
            snapshot.recentPlayers.insert(player, at: 0)
            snapshot.recentPlayers = Array(snapshot.recentPlayers.prefix(100))
        }
    }

    func clearRecentPlayers() {
        try? update { $0.recentPlayers.removeAll() }
    }

    func clearLastError() {
        lastError = nil
    }

    func reload() {
        guard let data = try? Data(contentsOf: storageURL),
              let stored = try? decoder.decode(SolFriendsSnapshot.self, from: data),
              stored.schemaVersion == 1 else { return }
        snapshot = stored
        lastError = nil
    }

    private func update(_ mutation: (inout SolFriendsSnapshot) -> Void) throws {
        var updated = snapshot
        mutation(&updated)

        do {
            try persist(updated)
            snapshot = updated
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func persist(_ snapshot: SolFriendsSnapshot) throws {
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: storageURL, options: .atomic)
        onPersistedChange?()
    }

    private func sanitized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func defaultStorageURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Sol", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent("friends-v1.json", isDirectory: false)
    }

    nonisolated private static func friendSort(
        _ lhs: SolFriend,
        _ rhs: SolFriend
    ) -> Bool {
        if lhs.isFavorite != rhs.isFavorite {
            return lhs.isFavorite
        }
        if lhs.presence != rhs.presence {
            return presenceRank(lhs.presence) < presenceRank(rhs.presence)
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    nonisolated private static func presenceRank(_ presence: SolFriendPresence) -> Int {
        switch presence {
        case .online: 0
        case .away: 1
        case .offline: 2
        }
    }
}
