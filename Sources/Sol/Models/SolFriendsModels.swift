import Foundation

struct SolSocialIdentity: Codable, Equatable, Sendable {
    var localProfileID: UUID
    var displayName: String
    var statusMessage: String
    var allowsFriendRequests: Bool
    var sharesPlayActivity: Bool
    var appearsInRecentPlayers: Bool
    var avatarSource: SolProfileAvatarSource? = nil
    var pixelAvatar: SolPixelAvatar? = nil
    var customAvatarRevision: UUID? = nil

    static func localDefault() -> SolSocialIdentity {
        let profileID = UUID()
        return SolSocialIdentity(
            localProfileID: profileID,
            displayName: "Sol Player",
            statusMessage: "Available to play",
            allowsFriendRequests: true,
            sharesPlayActivity: true,
            appearsInRecentPlayers: true,
            avatarSource: .pixel,
            pixelAvatar: .stableDefault(profileID: profileID),
            customAvatarRevision: nil
        )
    }

    var resolvedPixelAvatar: SolPixelAvatar {
        pixelAvatar ?? .stableDefault(profileID: localProfileID)
    }
}

enum SolFriendPresence: String, Codable, CaseIterable, Sendable {
    case online
    case away
    case offline
}

struct SolFriend: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var note: String
    var presence: SolFriendPresence
    var lastSeen: Date?
    var lastActivity: String?
    var isFavorite: Bool
    var addedAt: Date
}

struct SolFriendRequest: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var message: String?
    var receivedAt: Date
}

struct SolRecentPlayer: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var activity: String?
    var encounteredAt: Date
}

struct SolFriendsSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var identity: SolSocialIdentity
    var friends: [SolFriend]
    var requests: [SolFriendRequest]
    var recentPlayers: [SolRecentPlayer]

    static func empty() -> SolFriendsSnapshot {
        SolFriendsSnapshot(
            schemaVersion: 1,
            identity: .localDefault(),
            friends: [],
            requests: [],
            recentPlayers: []
        )
    }
}
