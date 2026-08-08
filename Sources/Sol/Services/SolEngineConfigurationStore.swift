import Combine
import Foundation

@MainActor
final class SolEngineConfigurationStore: ObservableObject {
    @Published private(set) var isLoaded = false
    @Published private(set) var lastError: String?
    @Published private(set) var configURL: URL?

    private var document: [String: Any] = [:]

    var startFullscreen: Bool {
        get { bool("start_fullscreen", default: false) }
        set { update("start_fullscreen", value: newValue) }
    }

    var dockedMode: Bool {
        get { bool("docked_mode", default: true) }
        set { update("docked_mode", value: newValue) }
    }

    var useHypervisor: Bool {
        get { bool("use_hypervisor", default: true) }
        set { update("use_hypervisor", value: newValue) }
    }

    var enablePTC: Bool {
        get { bool("enable_ptc", default: true) }
        set { update("enable_ptc", value: newValue) }
    }

    var enableLowPowerPTC: Bool {
        get { bool("enable_low_power_ptc", default: false) }
        set { update("enable_low_power_ptc", value: newValue) }
    }

    var enableMacroHLE: Bool {
        get { bool("enable_macro_hle", default: true) }
        set { update("enable_macro_hle", value: newValue) }
    }

    var gcLowLatency: Bool {
        get { bool("gclow_latency", default: true) }
        set { update("gclow_latency", value: newValue) }
    }

    var enableShaderCache: Bool {
        get { bool("enable_shader_cache", default: true) }
        set { update("enable_shader_cache", value: newValue) }
    }

    var enableTextureRecompression: Bool {
        get { bool("enable_texture_recompression", default: false) }
        set { update("enable_texture_recompression", value: newValue) }
    }

    var enableColorSpacePassthrough: Bool {
        get { bool("enable_color_space_passthrough", default: false) }
        set { update("enable_color_space_passthrough", value: newValue) }
    }

    var enableKeyboard: Bool {
        get { bool("enable_keyboard", default: false) }
        set { update("enable_keyboard", value: newValue) }
    }

    var enableMouse: Bool {
        get { bool("enable_mouse", default: false) }
        set { update("enable_mouse", value: newValue) }
    }

    var disableInputWhenOutOfFocus: Bool {
        get { bool("disable_input_when_out_of_focus", default: false) }
        set { update("disable_input_when_out_of_focus", value: newValue) }
    }

    var ignoreControllerApplet: Bool {
        get { bool("ignore_applet", default: false) }
        set { update("ignore_applet", value: newValue) }
    }

    var skipUserProfiles: Bool {
        get { bool("skip_user_profiles", default: false) }
        set { update("skip_user_profiles", value: newValue) }
    }

    var enableInternetAccess: Bool {
        get { bool("enable_internet_access", default: false) }
        set { update("enable_internet_access", value: newValue) }
    }

    var multiplayerMode: SolEngineMultiplayerMode {
        get {
            SolEngineMultiplayerMode(
                rawValue: integer("multiplayer_mode", default: SolEngineMultiplayerMode.disabled.rawValue)
            ) ?? .disabled
        }
        set { update("multiplayer_mode", value: newValue.rawValue) }
    }

    var multiplayerLanInterfaceID: String {
        get { string("multiplayer_lan_interface_id", default: "0") }
        set { update("multiplayer_lan_interface_id", value: newValue.isEmpty ? "0" : newValue) }
    }

    var multiplayerDisableP2P: Bool {
        get { bool("multiplayer_disable_p2p", default: false) }
        set { update("multiplayer_disable_p2p", value: newValue) }
    }

    var multiplayerLDNPassphrase: String {
        get { string("multiplayer_ldn_passphrase", default: "") }
        set { update("multiplayer_ldn_passphrase", value: String(newValue.prefix(16))) }
    }

    var multiplayerLDNServer: String {
        get { string("ldn_server", default: "") }
        set {
            update(
                "ldn_server",
                value: newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    var enableFSIntegrityChecks: Bool {
        get { bool("enable_fs_integrity_checks", default: true) }
        set { update("enable_fs_integrity_checks", value: newValue) }
    }

    var matchSystemTime: Bool {
        get { bool("match_system_time", default: true) }
        set { update("match_system_time", value: newValue) }
    }

    var systemTimeZone: String {
        get { string("system_time_zone", default: TimeZone.current.identifier) }
        set { update("system_time_zone", value: newValue) }
    }

    var resolutionScale: Int {
        get { integer("res_scale", default: 1) }
        set { update("res_scale", value: newValue) }
    }

    var customResolutionScale: Double {
        get { number("res_scale_custom", default: 1) }
        set { update("res_scale_custom", value: min(max(newValue, 0.5), 4)) }
    }

    var maxAnisotropy: Int {
        get { integer("max_anisotropy", default: -1) }
        set { update("max_anisotropy", value: newValue) }
    }

    var customVSyncInterval: Int {
        get { integer("custom_vsync_interval", default: 60) }
        set { update("custom_vsync_interval", value: newValue) }
    }

    var scalingFilterLevel: Int {
        get { integer("scaling_filter_level", default: 80) }
        set { update("scaling_filter_level", value: newValue) }
    }

    var audioVolume: Double {
        get { number("audio_volume", default: 1) }
        set { update("audio_volume", value: min(max(newValue, 0), 1)) }
    }

    var systemLanguage: SolEngineSystemLanguage {
        get {
            SolEngineSystemLanguage(
                rawValue: string("system_language", default: SolEngineSystemLanguage.americanEnglish.rawValue)
            ) ?? .americanEnglish
        }
        set { update("system_language", value: newValue.rawValue) }
    }

    var systemRegion: SolEngineSystemRegion {
        get {
            SolEngineSystemRegion(
                rawValue: string("system_region", default: SolEngineSystemRegion.usa.rawValue)
            ) ?? .usa
        }
        set { update("system_region", value: newValue.rawValue) }
    }

    var backendThreading: SolEngineBackendThreading {
        get {
            SolEngineBackendThreading(
                rawValue: string("backend_threading", default: SolEngineBackendThreading.automatic.rawValue)
            ) ?? .automatic
        }
        set { update("backend_threading", value: newValue.rawValue) }
    }

    var hideCursorMode: SolEngineHideCursorMode {
        get {
            SolEngineHideCursorMode(
                rawValue: integer("hide_cursor", default: SolEngineHideCursorMode.onIdle.rawValue)
            ) ?? .onIdle
        }
        set { update("hide_cursor", value: newValue.rawValue) }
    }

    var memoryConfiguration: SolEngineMemoryConfiguration {
        get {
            SolEngineMemoryConfiguration(
                rawValue: integer("dram_size", default: SolEngineMemoryConfiguration.fourGiB.rawValue)
            ) ?? .fourGiB
        }
        set { update("dram_size", value: newValue.rawValue) }
    }

    var memoryManagerMode: SolEngineMemoryManagerMode {
        get {
            SolEngineMemoryManagerMode(
                rawValue: string(
                    "memory_manager_mode",
                    default: SolEngineMemoryManagerMode.hostMappedUnsafe.rawValue
                )
            ) ?? .hostMappedUnsafe
        }
        set { update("memory_manager_mode", value: newValue.rawValue) }
    }

    var vsyncMode: SolEngineVSyncMode {
        get { SolEngineVSyncMode(rawValue: integer("vsync_mode", default: 0)) ?? .standardTiming }
        set { update("vsync_mode", value: newValue.rawValue) }
    }

    var aspectRatio: SolEngineAspectRatio {
        get { SolEngineAspectRatio(rawValue: string("aspect_ratio", default: SolEngineAspectRatio.fixed16x9.rawValue)) ?? .fixed16x9 }
        set { update("aspect_ratio", value: newValue.rawValue) }
    }

    var antiAliasing: SolEngineAntiAliasing {
        get { SolEngineAntiAliasing(rawValue: string("anti_aliasing", default: SolEngineAntiAliasing.none.rawValue)) ?? .none }
        set { update("anti_aliasing", value: newValue.rawValue) }
    }

    var scalingFilter: SolEngineScalingFilter {
        get { SolEngineScalingFilter(rawValue: string("scaling_filter", default: SolEngineScalingFilter.bilinear.rawValue)) ?? .bilinear }
        set { update("scaling_filter", value: newValue.rawValue) }
    }

    var audioBackend: SolEngineAudioBackend {
        get {
            let rawValue = string("audio_backend", default: SolEngineAudioBackend.audioToolbox.rawValue)
            return SolEngineAudioBackend(rawValue: rawValue) ?? .audioToolbox
        }
        set { update("audio_backend", value: newValue.rawValue) }
    }

    var autoloadDirectories: [String] {
        get { stringArray("autoload_dirs") }
        set {
            let normalized = newValue
                .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
                .filter { !$0.isEmpty }
            update(
                "autoload_dirs",
                value: Array(Set(normalized)).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
            )
        }
    }

    func connect(to dataDirectory: URL?) {
        guard let dataDirectory else {
            configURL = nil
            document = [:]
            isLoaded = false
            lastError = nil
            return
        }

        let newURL = dataDirectory.appendingPathComponent("Config.json")
        configURL = newURL
        reload()
    }

    func reload() {
        guard let configURL else {
            isLoaded = false
            return
        }

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            // A fresh install connects the settings UI before the bundled
            // backend has created its authoritative defaults. Treat that short
            // initialization window as pending instead of presenting an ENOENT
            // failure to the user. The backend status event reloads this store.
            document = [:]
            isLoaded = false
            lastError = nil
            objectWillChange.send()
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigurationError.invalidRoot
            }
            document = object
            isLoaded = true
            lastError = nil
            objectWillChange.send()
        } catch {
            document = [:]
            isLoaded = false
            lastError = error.localizedDescription
        }
    }

    private func update(_ key: String, value: Any) {
        guard configURL != nil else { return }
        objectWillChange.send()
        document[key] = value

        do {
            try save()
            isLoaded = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func save() throws {
        guard let configURL else { return }

        let backupURL = configURL.appendingPathExtension("native-ui-backup")
        if !FileManager.default.fileExists(atPath: backupURL.path),
           FileManager.default.fileExists(atPath: configURL.path) {
            try FileManager.default.copyItem(at: configURL, to: backupURL)
        }

        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: configURL, options: .atomic)
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        if let value = document[key] as? Bool { return value }
        return (document[key] as? NSNumber)?.boolValue ?? fallback
    }

    private func integer(_ key: String, default fallback: Int) -> Int {
        (document[key] as? NSNumber)?.intValue ?? fallback
    }

    private func number(_ key: String, default fallback: Double) -> Double {
        (document[key] as? NSNumber)?.doubleValue ?? fallback
    }

    private func string(_ key: String, default fallback: String) -> String {
        document[key] as? String ?? fallback
    }

    private func stringArray(_ key: String) -> [String] {
        if let values = document[key] as? [String] {
            return values
        }
        return (document[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private enum ConfigurationError: LocalizedError {
        case invalidRoot

        var errorDescription: String? {
            "Sol Engine configuration is not a JSON object."
        }
    }
}
