import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

struct AppleAccountRecord: Codable, Equatable {
    let userID: String
    var displayName: String
    var linkedProfileID: String?
    var email: String?
    var isPrivateRelay: Bool?
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
        let protectedResult = copyItem(useDataProtectionKeychain: true)
        switch protectedResult.status {
        case errSecSuccess:
            guard let data = protectedResult.data else {
                throw KeychainError(status: errSecDecode)
            }
            return try JSONDecoder().decode(AppleAccountRecord.self, from: data)
        case errSecItemNotFound:
            break
        default:
            throw KeychainError(status: protectedResult.status)
        }

        // Versions of Sol built before the account setup flow wrote to the
        // legacy file-backed keychain. Its ACL can become detached from a
        // rebuilt development app and macOS then surfaces the misleading
        // "user name or passphrase" error. Migrate readable records once;
        // otherwise let Sign in with Apple create a fresh protected record.
        let legacyResult = copyItem(useDataProtectionKeychain: false)
        switch legacyResult.status {
        case errSecSuccess:
            guard let data = legacyResult.data else {
                throw KeychainError(status: errSecDecode)
            }
            let record = try JSONDecoder().decode(AppleAccountRecord.self, from: data)
            try save(record)
            _ = deleteItem(useDataProtectionKeychain: false)
            return record
        case errSecItemNotFound, errSecAuthFailed, errSecInteractionNotAllowed:
            return nil
        default:
            throw KeychainError(status: legacyResult.status)
        }
    }

    private func copyItem(
        useDataProtectionKeychain: Bool
    ) -> (status: OSStatus, data: Data?) {
        var item: CFTypeRef?
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func save(_ record: AppleAccountRecord) throws {
        let data = try JSONEncoder().encode(record)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
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
                kSecUseDataProtectionKeychain: true,
            ] as CFDictionary,
            nil
        )
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func remove() throws {
        let status = deleteItem(useDataProtectionKeychain: true)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
        let legacyStatus = deleteItem(useDataProtectionKeychain: false)
        guard legacyStatus == errSecSuccess ||
                legacyStatus == errSecItemNotFound ||
                legacyStatus == errSecAuthFailed ||
                legacyStatus == errSecInteractionNotAllowed else {
            throw KeychainError(status: legacyStatus)
        }
    }

    private func deleteItem(useDataProtectionKeychain: Bool) -> OSStatus {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        return SecItemDelete(query as CFDictionary)
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                return "Sol could not unlock its saved Apple account. Sign in with Apple again to reconnect it."
            }
            return SecCopyErrorMessageString(status, nil) as String?
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
    @Published private(set) var email: String?
    @Published private(set) var isPrivateRelay = false
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
            email = record?.email
            isPrivateRelay = record?.isPrivateRelay ?? false
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

    /// A stable, non-reversible namespace used inside Sol's private iCloud
    /// container. The raw Sign in with Apple subject never becomes a filename
    /// or leaves Keychain.
    var cloudAccountIdentifier: String? {
        guard let record else { return nil }
        return Self.cloudAccountIdentifier(userID: record.userID)
    }

    var errorMessage: String? {
        guard case let .failed(message) = state else { return nil }
        return message
    }

    func prepareAuthorizationRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
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
            let existingEmail = record?.userID == credential.user
                ? record?.email
                : nil
            let name = suppliedName
                ?? existingName
                ?? Self.nonEmpty(profileName)
                ?? "Apple Account"
            let email = Self.nonEmpty(credential.email) ?? existingEmail
            let updatedRecord = AppleAccountRecord(
                userID: credential.user,
                displayName: name,
                linkedProfileID: profileID,
                email: email,
                isPrivateRelay: email?.localizedCaseInsensitiveContains(
                    "@privaterelay.appleid.com"
                ) ?? false
            )

            do {
                try credentialStore.save(updatedRecord)
                record = updatedRecord
                displayName = updatedRecord.displayName
                self.email = updatedRecord.email
                isPrivateRelay = updatedRecord.isPrivateRelay ?? false
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
            email = nil
            isPrivateRelay = false
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

    nonisolated static func cloudAccountIdentifier(userID: String) -> String {
        let digest = SHA256.hash(
            data: Data("com.solemu.app.cloud.\(userID)".utf8)
        )
        let suffix = digest.prefix(20)
            .map { String(format: "%02x", $0) }
            .joined()
        return "apple-\(suffix)"
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
