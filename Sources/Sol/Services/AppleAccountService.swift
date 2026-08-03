import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

struct AppleAccountRecord: Codable, Equatable {
    let userID: String
    var displayName: String
    var linkedProfileID: String?
}

protocol AppleAccountCredentialStoring {
    func load() throws -> AppleAccountRecord?
    func save(_ record: AppleAccountRecord) throws
    func remove() throws
}

struct KeychainAppleAccountCredentialStore: AppleAccountCredentialStoring {
    private let service = "com.solemu.app.apple-account"
    private let account = "primary"

    func load() throws -> AppleAccountRecord? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary,
            &item
        )

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(AppleAccountRecord.self, from: data)
    }

    func save(_ record: AppleAccountRecord) throws {
        let data = try JSONEncoder().encode(record)
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary
        let attributes = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary

        let updateStatus = SecItemUpdate(query, attributes)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        let addStatus = SecItemAdd(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary,
            nil
        )
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func remove() throws {
        let status = SecItemDelete(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ] as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String?
                ?? "The Apple account could not be saved in Keychain."
        }
    }
}

@MainActor
final class AppleAccountService: ObservableObject {
    enum State: Equatable {
        case checking
        case signedOut
        case connected
        case revoked
        case requiresSignedBuild
        case failed(String)

        var title: String {
            switch self {
            case .checking:
                return "Checking Apple Account"
            case .signedOut:
                return "Not signed in"
            case .connected:
                return "Connected with Apple"
            case .revoked:
                return "Apple access was revoked"
            case .requiresSignedBuild:
                return "Signed build required"
            case .failed:
                return "Apple Account unavailable"
            }
        }

        var systemImage: String {
            switch self {
            case .checking:
                return "person.crop.circle.badge.clock"
            case .signedOut:
                return "person.crop.circle.badge.plus"
            case .connected:
                return "person.crop.circle.badge.checkmark"
            case .revoked:
                return "person.crop.circle.badge.exclamationmark"
            case .requiresSignedBuild:
                return "signature"
            case .failed:
                return "exclamationmark.triangle"
            }
        }
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var displayName: String?
    @Published private(set) var linkedProfileID: String?

    private let credentialStore: any AppleAccountCredentialStoring
    private let entitlementAvailable: Bool
    private var record: AppleAccountRecord?

    init(
        credentialStore: any AppleAccountCredentialStoring = KeychainAppleAccountCredentialStore(),
        entitlementChecker: (() -> Bool)? = nil
    ) {
        self.credentialStore = credentialStore
        self.entitlementAvailable =
            entitlementChecker?() ?? Self.hasSignInWithAppleEntitlement

        guard entitlementAvailable else {
            state = .requiresSignedBuild
            return
        }

        do {
            record = try credentialStore.load()
            displayName = record?.displayName
            linkedProfileID = record?.linkedProfileID
            if record == nil {
                state = .signedOut
            } else {
                refreshCredentialState()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var isConnected: Bool {
        state == .connected
    }

    var avatarURL: URL? {
        guard let record else { return nil }
        return Self.avatarURL(userID: record.userID, displayName: record.displayName)
    }

    var errorMessage: String? {
        guard case let .failed(message) = state else { return nil }
        return message
    }

    func prepareAuthorizationRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName]
    }

    func completeAuthorization(
        _ result: Result<ASAuthorization, Error>,
        linkingProfileID profileID: String?,
        profileName: String?
    ) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                state = .failed("Apple returned an unsupported account credential.")
                return
            }

            let suppliedName = credential.fullName
                .map { PersonNameComponentsFormatter().string(from: $0) }
                .flatMap(Self.nonEmpty)
            let existingName = record?.userID == credential.user
                ? record?.displayName
                : nil
            let name = suppliedName
                ?? existingName
                ?? Self.nonEmpty(profileName)
                ?? "Apple Account"
            let updatedRecord = AppleAccountRecord(
                userID: credential.user,
                displayName: name,
                linkedProfileID: profileID
            )

            do {
                try credentialStore.save(updatedRecord)
                record = updatedRecord
                displayName = updatedRecord.displayName
                linkedProfileID = updatedRecord.linkedProfileID
                state = .connected
            } catch {
                state = .failed(error.localizedDescription)
            }

        case let .failure(error):
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                return
            }
            state = .failed(error.localizedDescription)
        }
    }

    func refreshCredentialState() {
        guard entitlementAvailable else {
            state = .requiresSignedBuild
            return
        }
        guard let record else {
            state = .signedOut
            return
        }

        state = .checking
        ASAuthorizationAppleIDProvider().getCredentialState(
            forUserID: record.userID
        ) { [weak self] credentialState, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }

                switch credentialState {
                case .authorized:
                    self.state = .connected
                case .revoked:
                    self.state = .revoked
                case .notFound:
                    self.clearStoredAccount(nextState: .signedOut)
                case .transferred:
                    self.state = .signedOut
                @unknown default:
                    self.state = .failed("Apple returned an unknown credential state.")
                }
            }
        }
    }

    func linkMultiplayerProfile(_ profileID: String) {
        guard !profileID.isEmpty, var record else { return }
        guard record.linkedProfileID != profileID else { return }

        record.linkedProfileID = profileID
        do {
            try credentialStore.save(record)
            self.record = record
            linkedProfileID = profileID
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func adoptCloudMultiplayerProfile(_ profileID: String) {
        guard isConnected else { return }
        linkMultiplayerProfile(profileID)
    }

    func disconnect() {
        clearStoredAccount(nextState: .signedOut)
    }

    private func clearStoredAccount(nextState: State) {
        do {
            try credentialStore.remove()
            record = nil
            displayName = nil
            linkedProfileID = nil
            state = nextState
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    nonisolated static func avatarURL(userID: String, displayName: String) -> URL? {
        let slug = displayName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(3)
            .joined(separator: "-")
        let digest = SHA256.hash(
            data: Data("com.solemu.app.avatar.\(userID)".utf8)
        )
        let suffix = digest.prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        let seed = "\((slug.isEmpty ? "sol-player" : slug).prefix(32))-\(suffix)"

        var components = URLComponents()
        components.scheme = "https"
        components.host = "avatar.vercel.sh"
        components.path = "/\(seed)"
        components.queryItems = [
            URLQueryItem(name: "rounded", value: "60"),
            URLQueryItem(name: "size", value: "120"),
        ]
        return components.url
    }

    private static var hasSignInWithAppleEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let values = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.applesignin" as CFString,
                  nil
              ) as? [String] else {
            return false
        }
        return values.contains("Default")
    }
}
