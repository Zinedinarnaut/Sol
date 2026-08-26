import AppKit
import Combine
import Foundation
import Security

@MainActor
final class SolCloudSyncService: ObservableObject {
    static let containerIdentifier = "iCloud.com.solemu.app"

    @Published private(set) var state: SolCloudSyncState = .waitingForAppleAccount
    @Published private(set) var latestBackup: SolCloudBackupSummary?
    @Published private(set) var lastRecoveryURL: URL?
    @Published private(set) var lastRestoreID: UUID?
    @Published var automaticSyncEnabled: Bool {
        didSet {
            defaults.set(automaticSyncEnabled, forKey: Self.automaticSyncKey)
            if automaticSyncEnabled {
                synchronize(reason: .manual)
            }
        }
    }

    private static let automaticSyncKey = "sol.cloud.automatic-sync"
    private static let deviceIdentifierKey = "sol.cloud.device-identifier"
    private static let lastAccountIdentifierKey = "sol.cloud.last-account-identifier"

    private let coordinator: SolCloudBackupCoordinator
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let explicitCloudRootURL: URL?
    private let localStateRootURL: URL
    private let profileRootURL: URL
    private let deviceIdentifier: String

    private var accountIdentifier: String?
    private var engineRootURL: URL?
    private var launcherSettingsData: Data?
    private var isGameplayActive = false
    private var needsAccountChangeReview = false
    private var pendingReason: SolCloudSyncReason?
    private var synchronizationTask: Task<Void, Never>?
    private var identityObserver: AnyCancellable?

    var onRestore: ((Data?) -> Void)?

    init(
        coordinator: SolCloudBackupCoordinator = SolCloudBackupCoordinator(),
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        cloudRootURL: URL? = nil,
        localStateRootURL: URL? = nil,
        profileRootURL: URL? = nil
    ) {
        self.coordinator = coordinator
        self.fileManager = fileManager
        self.defaults = defaults
        self.explicitCloudRootURL = cloudRootURL

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let solSupport = applicationSupport.appendingPathComponent("Sol", isDirectory: true)
        self.localStateRootURL = localStateRootURL
            ?? solSupport.appendingPathComponent("Cloud", isDirectory: true)
        self.profileRootURL = profileRootURL
            ?? solSupport.appendingPathComponent("Profiles", isDirectory: true)

        if let stored = defaults.string(forKey: Self.deviceIdentifierKey), !stored.isEmpty {
            deviceIdentifier = stored
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: Self.deviceIdentifierKey)
            deviceIdentifier = generated
        }

        if defaults.object(forKey: Self.automaticSyncKey) == nil {
            // First-run setup asks before enabling background uploads. Existing
            // users keep their saved choice unchanged.
            automaticSyncEnabled = false
            defaults.set(false, forKey: Self.automaticSyncKey)
        } else {
            automaticSyncEnabled = defaults.bool(forKey: Self.automaticSyncKey)
        }

        identityObserver = NotificationCenter.default.publisher(
            for: NSNotification.Name.NSUbiquityIdentityDidChange
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.refreshAvailabilityAndSync()
        }
    }

    deinit {
        synchronizationTask?.cancel()
    }

    func configure(
        accountIdentifier: String?,
        engineRootURL: URL?,
        launcherSettingsData: Data?
    ) {
        let accountChanged = self.accountIdentifier != accountIdentifier
        let rootChanged = self.engineRootURL != engineRootURL
        if let accountIdentifier {
            if let previous = defaults.string(forKey: Self.lastAccountIdentifierKey),
               previous != accountIdentifier {
                needsAccountChangeReview = true
            } else if defaults.string(forKey: Self.lastAccountIdentifierKey) == nil {
                defaults.set(accountIdentifier, forKey: Self.lastAccountIdentifierKey)
                needsAccountChangeReview = false
            }
        } else {
            needsAccountChangeReview = false
        }
        self.accountIdentifier = accountIdentifier
        self.engineRootURL = engineRootURL
        self.launcherSettingsData = launcherSettingsData

        refreshAvailability()
        if automaticSyncEnabled,
           !needsAccountChangeReview,
           (accountChanged || rootChanged),
           accountIdentifier != nil,
           engineRootURL != nil {
            synchronize(reason: .accountChanged)
        }
    }

    func updateLauncherSettingsData(_ data: Data?) {
        launcherSettingsData = data
    }

    func setGameplayActive(_ active: Bool) {
        guard isGameplayActive != active else { return }
        isGameplayActive = active
        if active {
            if synchronizationTask != nil {
                pendingReason = pendingReason ?? .gameplayEnded
            }
        } else if let reason = pendingReason {
            pendingReason = nil
            synchronize(reason: reason)
        }
    }

    func synchronize(reason: SolCloudSyncReason) {
        guard automaticSyncEnabled || reason == .manual else { return }
        guard !needsAccountChangeReview else {
            state = .accountChangeReview
            return
        }
        guard !isGameplayActive else {
            pendingReason = reason
            state = .deferredForGame
            return
        }
        guard synchronizationTask == nil else {
            pendingReason = reason
            return
        }
        guard let context = makeContext() else {
            refreshAvailability()
            return
        }

        run(mode: .automatic, context: context, reason: reason)
    }

    func backUpNow() {
        guard !isGameplayActive else {
            pendingReason = .manual
            state = .deferredForGame
            return
        }
        guard synchronizationTask == nil,
              let context = makeContext() else {
            refreshAvailability()
            return
        }
        run(mode: .keepThisMac, context: context, reason: .manual)
    }

    func keepThisMac() {
        backUpNow()
    }

    func useICloud() {
        guard !isGameplayActive else {
            pendingReason = .manual
            state = .deferredForGame
            return
        }
        guard synchronizationTask == nil,
              let context = makeContext() else {
            refreshAvailability()
            return
        }
        run(mode: .useICloud, context: context, reason: .manual)
    }

    func revealRecoveryFolder() {
        guard let lastRecoveryURL else { return }
        try? fileManager.createDirectory(
            at: lastRecoveryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([lastRecoveryURL])
    }

    private func run(
        mode: SolCloudReconciliationMode,
        context: SolCloudSyncContext,
        reason: SolCloudSyncReason
    ) {
        state = .syncing(syncMessage(for: reason, mode: mode))
        synchronizationTask = Task { [weak self, coordinator] in
            do {
                let result = try await coordinator.reconcile(context: context, mode: mode)
                guard !Task.isCancelled else { return }
                self?.apply(result)
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }

            guard let self else { return }
            self.synchronizationTask = nil
            if let pendingReason = self.pendingReason, !self.isGameplayActive {
                self.pendingReason = nil
                self.synchronize(reason: pendingReason)
            }
        }
    }

    private func apply(_ result: SolCloudReconciliationResult) {
        if let manifest = result.manifest {
            latestBackup = SolCloudBackupSummary(manifest: manifest)
        }
        if let recoveryURL = result.recoveryURL {
            lastRecoveryURL = recoveryURL
        }

        switch result.outcome {
        case .uploaded, .unchanged:
            markCurrentAccountReviewed()
            state = .synced(result.manifest?.createdAt ?? Date())
        case .restored:
            markCurrentAccountReviewed()
            lastRestoreID = result.manifest?.id
            onRestore?(result.restoredLauncherSettingsData)
            state = .synced(result.manifest?.createdAt ?? Date())
        case .conflict:
            state = .conflict(cloudDate: result.manifest?.createdAt ?? Date())
        }
    }

    private func refreshAvailabilityAndSync() {
        refreshAvailability()
        if automaticSyncEnabled {
            synchronize(reason: .accountChanged)
        }
    }

    private func refreshAvailability() {
        guard accountIdentifier != nil else {
            state = .waitingForAppleAccount
            return
        }
        guard Self.hasDocumentsEntitlement || explicitCloudRootURL != nil else {
            state = .requiresSignedBuild
            return
        }
        guard fileManager.ubiquityIdentityToken != nil || explicitCloudRootURL != nil else {
            state = .waitingForICloud
            return
        }
        guard engineRootURL != nil else {
            state = .ready
            return
        }
        if needsAccountChangeReview {
            state = .accountChangeReview
            return
        }
        if synchronizationTask == nil {
            state = .ready
        }
    }

    private func markCurrentAccountReviewed() {
        guard let accountIdentifier else { return }
        defaults.set(accountIdentifier, forKey: Self.lastAccountIdentifierKey)
        needsAccountChangeReview = false
    }

    private func makeContext() -> SolCloudSyncContext? {
        guard let accountIdentifier,
              let engineRootURL,
              let cloudRootURL = resolvedCloudRootURL() else { return nil }
        return SolCloudSyncContext(
            accountIdentifier: accountIdentifier,
            deviceIdentifier: deviceIdentifier,
            engineRootURL: engineRootURL,
            profileRootURL: profileRootURL,
            localStateRootURL: localStateRootURL,
            cloudRootURL: cloudRootURL,
            launcherSettingsData: launcherSettingsData
        )
    }

    private func resolvedCloudRootURL() -> URL? {
        if let explicitCloudRootURL {
            return explicitCloudRootURL
        }
        guard Self.hasDocumentsEntitlement,
              fileManager.ubiquityIdentityToken != nil,
              let container = fileManager.url(
                  forUbiquityContainerIdentifier: Self.containerIdentifier
              ) else { return nil }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Sol Cloud", isDirectory: true)
    }

    private func syncMessage(
        for reason: SolCloudSyncReason,
        mode: SolCloudReconciliationMode
    ) -> String {
        switch mode {
        case .keepThisMac: return "Backing Up This Mac"
        case .useICloud: return "Restoring from iCloud"
        case .automatic:
            switch reason {
            case .screenshotCaptured: return "Saving Screenshot to iCloud"
            case .gameplayEnded: return "Backing Up Game Data"
            case .settingsChanged: return "Backing Up Settings"
            default: return "Syncing with iCloud"
            }
        }
    }

    private static var hasDocumentsEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let values = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.ubiquity-container-identifiers" as CFString,
                  nil
              ) as? [String] else {
            return false
        }
        return values.contains(containerIdentifier)
    }
}
