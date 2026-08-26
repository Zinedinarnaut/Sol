import Foundation
import XCTest
@testable import Sol

final class SolFriendsStoreTests: XCTestCase {
    @MainActor
    func testLegacyUpstreamDefaultNameMigratesToSolIdentity() throws {
        let (temporaryDirectory, storageURL) = try makeStorageURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let legacySnapshot = SolFriendsSnapshot(
            schemaVersion: 1,
            identity: SolSocialIdentity(
                localProfileID: UUID(),
                displayName: "RyuPlayer",
                statusMessage: "Available to play",
                allowsFriendRequests: true,
                sharesPlayActivity: true,
                appearsInRecentPlayers: true
            ),
            friends: [],
            requests: [],
            recentPlayers: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacySnapshot).write(to: storageURL)

        let store = SolFriendsStore(storageURL: storageURL)
        store.prepareIdentity(defaultDisplayName: "Sol Player")

        XCTAssertEqual(store.identity.displayName, "Sol Player")
    }

    @MainActor
    func testIdentityAndLocalFriendPersistAcrossLaunches() throws {
        let (temporaryDirectory, storageURL) = try makeStorageURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SolFriendsStore(storageURL: storageURL)
        try store.updateIdentity(
            displayName: "Solstice",
            statusMessage: "Ready to play",
            allowsFriendRequests: false,
            sharesPlayActivity: true,
            appearsInRecentPlayers: false
        )
        try store.addLocalFriend(displayName: "Avery", note: "Met locally")

        let restored = SolFriendsStore(storageURL: storageURL)

        XCTAssertEqual(restored.identity.displayName, "Solstice")
        XCTAssertEqual(restored.identity.statusMessage, "Ready to play")
        XCTAssertFalse(restored.identity.allowsFriendRequests)
        XCTAssertTrue(restored.identity.sharesPlayActivity)
        XCTAssertFalse(restored.identity.appearsInRecentPlayers)
        XCTAssertEqual(restored.friends.map(\.displayName), ["Avery"])
        XCTAssertEqual(restored.friends.first?.note, "Met locally")
    }

    @MainActor
    func testPixelAvatarSelectionPersistsAcrossLaunches() throws {
        let (temporaryDirectory, storageURL) = try makeStorageURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SolFriendsStore(storageURL: storageURL)
        let avatar = SolPixelAvatar(seed: 2_026, style: .violet)

        try store.updateIdentity(
            displayName: "Solstice",
            statusMessage: "Ready to play",
            allowsFriendRequests: true,
            sharesPlayActivity: true,
            appearsInRecentPlayers: true,
            avatarSource: .pixel,
            pixelAvatar: avatar
        )

        let restored = SolFriendsStore(storageURL: storageURL)

        XCTAssertEqual(restored.identity.avatarSource, .pixel)
        XCTAssertEqual(restored.identity.pixelAvatar, avatar)
    }

    @MainActor
    func testCustomAvatarRevisionPersistsAcrossLaunches() throws {
        let (temporaryDirectory, storageURL) = try makeStorageURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SolFriendsStore(storageURL: storageURL)
        let revision = UUID()

        try store.updateIdentity(
            displayName: "Solstice",
            statusMessage: "Ready to play",
            allowsFriendRequests: true,
            sharesPlayActivity: true,
            appearsInRecentPlayers: true,
            avatarSource: .custom,
            pixelAvatar: store.identity.resolvedPixelAvatar,
            customAvatarRevision: revision
        )

        let restored = SolFriendsStore(storageURL: storageURL)

        XCTAssertEqual(restored.identity.avatarSource, .custom)
        XCTAssertEqual(restored.identity.customAvatarRevision, revision)
    }

    @MainActor
    func testActiveGameUserBecomesTheIdentityAcrossSol() throws {
        let (temporaryDirectory, storageURL) = try makeStorageURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SolFriendsStore(storageURL: storageURL)
        let pixelAvatar = store.identity.resolvedPixelAvatar

        try store.updateIdentity(
            displayName: "Sol Player",
            statusMessage: "Ready to race",
            allowsFriendRequests: false,
            sharesPlayActivity: true,
            appearsInRecentPlayers: false,
            avatarSource: .pixel,
            pixelAvatar: pixelAvatar
        )

        store.synchronizeActiveGameUser(displayName: "Ziz")

        let restored = SolFriendsStore(storageURL: storageURL)
        XCTAssertEqual(restored.identity.displayName, "Ziz")
        XCTAssertEqual(restored.identity.avatarSource, .gameProfile)
        XCTAssertEqual(restored.identity.statusMessage, "Ready to race")
        XCTAssertFalse(restored.identity.allowsFriendRequests)
        XCTAssertTrue(restored.identity.sharesPlayActivity)
        XCTAssertFalse(restored.identity.appearsInRecentPlayers)
        XCTAssertEqual(restored.identity.pixelAvatar, pixelAvatar)
    }

    @MainActor
    func testLegacyGameUserNameDoesNotReplaceTheSolIdentity() throws {
        let (temporaryDirectory, storageURL) = try makeStorageURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SolFriendsStore(storageURL: storageURL)

        store.synchronizeActiveGameUser(displayName: "RyuPlayer")

        XCTAssertEqual(store.identity.displayName, "Sol Player")
        XCTAssertEqual(store.identity.avatarSource, .pixel)
    }

    @MainActor
    func testDuplicateFriendNamesAreRejectedCaseInsensitively() throws {
        let (temporaryDirectory, storageURL) = try makeStorageURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SolFriendsStore(storageURL: storageURL)
        try store.addLocalFriend(displayName: "Avery")

        XCTAssertThrowsError(
            try store.addLocalFriend(displayName: "avery")
        ) { error in
            XCTAssertEqual(error as? SolFriendsStoreError, .duplicateFriend)
        }
        XCTAssertEqual(store.friends.count, 1)
    }

    @MainActor
    func testRequestCanBeAcceptedIntoFriendsList() throws {
        let (temporaryDirectory, storageURL) = try makeStorageURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SolFriendsStore(storageURL: storageURL)
        try store.recordIncomingRequest(
            displayName: "Jordan",
            message: "Want to play?"
        )
        let requestID = try XCTUnwrap(store.requests.first?.id)

        try store.acceptRequest(id: requestID)

        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertEqual(store.friends.map(\.displayName), ["Jordan"])
    }

    @MainActor
    func testRecentPlayerUpdatesInsteadOfDuplicatingStableIdentity() throws {
        let (temporaryDirectory, storageURL) = try makeStorageURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SolFriendsStore(storageURL: storageURL)
        let playerID = UUID()
        try store.recordRecentPlayer(
            id: playerID,
            displayName: "Morgan",
            activity: "First room",
            encounteredAt: Date(timeIntervalSince1970: 100)
        )
        try store.recordRecentPlayer(
            id: playerID,
            displayName: "Morgan",
            activity: "Second room",
            encounteredAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.recentPlayers.count, 1)
        XCTAssertEqual(store.recentPlayers.first?.activity, "Second room")
        XCTAssertEqual(
            store.recentPlayers.first?.encounteredAt,
            Date(timeIntervalSince1970: 200)
        )
    }

    private func makeStorageURL() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (directory, directory.appendingPathComponent("friends-v1.json"))
    }
}
