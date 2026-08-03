import Combine
import Foundation
import Security

@MainActor
final class ICloudProfileSyncService: ObservableObject {
    enum Availability: Equatable {
        case available
        case signedOut
        case requiresSignedBuild

        var title: String {
            switch self {
            case .available:
                return "Synced with iCloud"
            case .signedOut:
                return "Sign in to iCloud"
            case .requiresSignedBuild:
                return "Signed build required"
            }
        }

        var systemImage: String {
            switch self {
            case .available:
                return "icloud.fill"
            case .signedOut:
                return "icloud.slash"
            case .requiresSignedBuild:
                return "signature"
            }
        }
    }

    @Published private(set) var availability: Availability = .requiresSignedBuild
    @Published private(set) var selectedProfileID: String?
    @Published private(set) var multiplayerProfileID: String?

    private static let selectedProfileKey = "sol.profile.selected"
    private static let multiplayerProfileKey = "sol.multiplayer.profile"
    private let store: NSUbiquitousKeyValueStore?
    private var changeCancellable: AnyCancellable?

    init(store: NSUbiquitousKeyValueStore? = nil) {
        guard Self.hasKeyValueStoreEntitlement else {
            self.store = nil
            availability = .requiresSignedBuild
            return
        }

        let activeStore = store ?? .default
        self.store = activeStore
        changeCancellable = NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: activeStore
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.refresh()
        }
        refresh()
        activeStore.synchronize()
    }

    func publishSelectedProfile(_ profileID: String) {
        guard !profileID.isEmpty else { return }
        guard let store else {
            availability = .requiresSignedBuild
            return
        }
        guard selectedProfileID != profileID else {
            refreshAvailability()
            return
        }
        store.set(profileID, forKey: Self.selectedProfileKey)
        selectedProfileID = profileID
        store.synchronize()
        refreshAvailability()
    }

    func publishMultiplayerProfile(_ profileID: String) {
        guard !profileID.isEmpty else { return }
        guard let store else {
            availability = .requiresSignedBuild
            return
        }
        guard multiplayerProfileID != profileID else {
            refreshAvailability()
            return
        }
        store.set(profileID, forKey: Self.multiplayerProfileKey)
        multiplayerProfileID = profileID
        store.synchronize()
        refreshAvailability()
    }

    func clearMultiplayerProfile() {
        guard let store else {
            multiplayerProfileID = nil
            return
        }
        guard multiplayerProfileID != nil else {
            refreshAvailability()
            return
        }
        store.removeObject(forKey: Self.multiplayerProfileKey)
        multiplayerProfileID = nil
        store.synchronize()
        refreshAvailability()
    }

    func refresh() {
        refreshAvailability()
        selectedProfileID = store?.string(forKey: Self.selectedProfileKey)
        multiplayerProfileID = store?.string(forKey: Self.multiplayerProfileKey)
    }

    private func refreshAvailability() {
        guard Self.hasKeyValueStoreEntitlement else {
            availability = .requiresSignedBuild
            return
        }
        availability = FileManager.default.ubiquityIdentityToken == nil
            ? .signedOut
            : .available
    }

    private static var hasKeyValueStoreEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return false
        }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.ubiquity-kvstore-identifier" as CFString,
            nil
        ) as? String else {
            return false
        }
        return !value.isEmpty
    }
}
