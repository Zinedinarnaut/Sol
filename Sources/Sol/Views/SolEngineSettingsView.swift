import AppKit
import SwiftUI
import SolDLSM

struct SolEngineEmulationSettingsPane: View {
    @ObservedObject var configuration: SolEngineConfigurationStore

    var body: some View {
        Group {
            if configuration.isLoaded {
                Form {
                    Section("Console Environment") {
                        Picker("System language", selection: binding(\.systemLanguage)) {
                            ForEach(SolEngineSystemLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }

                        Picker("System region", selection: binding(\.systemRegion)) {
                            ForEach(SolEngineSystemRegion.allCases) { region in
                                Text(region.title).tag(region)
                            }
                        }

                        Toggle("Docked mode", isOn: binding(\.dockedMode))
                        Toggle("Match Mac date and time", isOn: binding(\.matchSystemTime))

                        if !configuration.matchSystemTime {
                            Picker("Time zone", selection: binding(\.systemTimeZone)) {
                                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                                    Text(identifier.replacingOccurrences(of: "_", with: " "))
                                        .tag(identifier)
                                }
                            }
                        }
                    }

                    Section("CPU and Memory") {
                        Toggle("Use Apple Hypervisor", isOn: binding(\.useHypervisor))
                        Toggle("Enable PTC", isOn: binding(\.enablePTC))
                        Toggle("Low-power PTC loading", isOn: binding(\.enableLowPowerPTC))
                            .disabled(!configuration.enablePTC)
                        Toggle("Macro HLE", isOn: binding(\.enableMacroHLE))
                        Toggle("Low-latency garbage collection", isOn: binding(\.gcLowLatency))

                        Picker("Memory size", selection: binding(\.memoryConfiguration)) {
                            ForEach(SolEngineMemoryConfiguration.allCases) { configuration in
                                Text(configuration.title).tag(configuration)
                            }
                        }

                        Picker("Memory manager", selection: binding(\.memoryManagerMode)) {
                            ForEach(SolEngineMemoryManagerMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }

                    Section("Launch and Input") {
                        Toggle("Start games in full screen", isOn: binding(\.startFullscreen))
                        Toggle("Enable keyboard input", isOn: binding(\.enableKeyboard))
                        Toggle("Enable mouse input", isOn: binding(\.enableMouse))
                        Toggle(
                            "Disable input when game is in background",
                            isOn: binding(\.disableInputWhenOutOfFocus)
                        )

                        Picker("Hide cursor", selection: binding(\.hideCursorMode)) {
                            ForEach(SolEngineHideCursorMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        Toggle(
                            "Ignore controller applet warnings",
                            isOn: binding(\.ignoreControllerApplet)
                        )
                        Toggle("Skip user profile chooser", isOn: binding(\.skipUserProfiles))
                    }

                    Section("Network and Content") {
                        Toggle("Guest internet access", isOn: binding(\.enableInternetAccess))
                        Toggle("Verify game content integrity", isOn: binding(\.enableFSIntegrityChecks))
                    }

                    if let configURL = configuration.configURL {
                        Section("Configuration") {
                            LabeledContent("File") {
                                Text(configURL.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                unavailableView(
                    title: "Sol Engine Configuration Unavailable",
                    systemImage: "gearshape.2"
                )
            }
        }
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<SolEngineConfigurationStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { configuration[keyPath: keyPath] = $0 }
        )
    }

    private func unavailableView(title: String, systemImage: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(configuration.lastError ?? "Build and embed the bundled native Sol Engine runtime.")
        )
    }
}

struct SolEngineGraphicsSettingsPane: View {
    @ObservedObject var configuration: SolEngineConfigurationStore
    @ObservedObject var settings: SettingsStore
    let providerStatus: DLSMProviderStatus
    private var dlsmCapabilities: DLSMCapabilities { .current }

    var body: some View {
        Group {
            if configuration.isLoaded {
                Form {
                    Section("Rendering") {
                        LabeledContent("Graphics API") {
                            Text("Vulkan via MoltenVK")
                                .foregroundStyle(.secondary)
                        }

                        Picker("Backend threading", selection: binding(\.backendThreading)) {
                            ForEach(SolEngineBackendThreading.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        Picker("Resolution scale", selection: binding(\.resolutionScale)) {
                            Text("Custom").tag(-1)
                            Text("Native (1×)").tag(1)
                            Text("2×").tag(2)
                            Text("3×").tag(3)
                            Text("4×").tag(4)
                        }

                        if configuration.resolutionScale == -1 {
                            LabeledContent("Custom scale") {
                                HStack {
                                    Slider(
                                        value: binding(\.customResolutionScale),
                                        in: 0.5...4,
                                        step: 0.1
                                    )
                                    .frame(width: 190)
                                    Text(
                                        configuration.customResolutionScale,
                                        format: .number.precision(.fractionLength(1))
                                    )
                                    .monospacedDigit()
                                    .frame(width: 34, alignment: .trailing)
                                }
                            }
                        }

                        Picker("Aspect ratio", selection: binding(\.aspectRatio)) {
                            ForEach(SolEngineAspectRatio.allCases) { ratio in
                                Text(ratio.title).tag(ratio)
                            }
                        }

                        Picker("VSync", selection: binding(\.vsyncMode)) {
                            ForEach(SolEngineVSyncMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        if configuration.vsyncMode == .custom {
                            Stepper(
                                "Custom refresh rate: \(configuration.customVSyncInterval) Hz",
                                value: binding(\.customVSyncInterval),
                                in: 30...360
                            )
                        }

                        Picker("Anisotropic filtering", selection: binding(\.maxAnisotropy)) {
                            Text("Automatic").tag(-1)
                            Text("2×").tag(2)
                            Text("4×").tag(4)
                            Text("8×").tag(8)
                            Text("16×").tag(16)
                        }
                    }

                    Section("Image Quality") {
                        Picker("Anti-aliasing", selection: binding(\.antiAliasing)) {
                            ForEach(SolEngineAntiAliasing.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        Picker("Scaling filter", selection: binding(\.scalingFilter)) {
                            ForEach(SolEngineScalingFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }

                        if configuration.scalingFilter == .fsr {
                            LabeledContent("FSR sharpness") {
                                Slider(
                                    value: integerSliderBinding(\.scalingFilterLevel),
                                    in: 0...100,
                                    step: 1
                                )
                                .frame(width: 220)
                            }
                        }

                        Toggle("Shader cache", isOn: binding(\.enableShaderCache))
                        Toggle("Texture recompression", isOn: binding(\.enableTextureRecompression))
                        Toggle(
                            "Color space passthrough",
                            isOn: binding(\.enableColorSpacePassthrough)
                        )
                    }

                    if DLSMFeatureGate.isEnabled {
                        Section("DLSM — Deep Learning Super Metal") {
                        LabeledContent("Apple GPU") {
                            Label(
                                dlsmCapabilities.gpuName,
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)
                        }

                        if !dlsmCapabilities.hasNativeTemporalInputs {
                            Label(
                                dlsmCapabilities.hasSolTemporalModel
                                    ? "The trained Sol Temporal model is installed and can provide motion and reactive confidence."
                                    : dlsmCapabilities.allowsExperimentalTemporal
                                        ? "The experimental block matcher is enabled for local capture and research. It can ghost pulsing UI and is not a production provider."
                                    : dlsmCapabilities.hasNativeFrameBridge
                                        ? "Spatial is stable. Temporal now waits for the trained Sol model or validated game-authored motion instead of reusing unsafe reconstructed history."
                                        : "Spatial is the stable DLSM mode. Temporal requires a depth and motion provider.",
                                systemImage: dlsmCapabilities.hasSolTemporalModel
                                    ? "sparkles.rectangle.stack"
                                    : "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                dlsmCapabilities.hasSolTemporalModel
                                    ? Color.blue
                                    : Color.orange
                            )
                        }

                        LabeledContent("Provider milestone") {
                            Label(
                                providerStatus.stageTitle,
                                systemImage: providerStatus.exportReady
                                    ? "checkmark.seal.fill"
                                    : providerStatus.rawExportReady
                                        ? "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
                                    : providerStatus.depthReady
                                        ? "circle.dotted.circle.fill"
                                        : "waveform.path.ecg"
                            )
                            .foregroundStyle(
                                providerStatus.exportReady
                                    ? Color.green
                                    : providerStatus.rawExportReady
                                        ? Color.blue
                                        : Color.secondary
                            )
                        }

                        if providerStatus.stage != "waiting" {
                            LabeledContent("Scene candidate") {
                                providerReadinessLabel(
                                    providerStatus.sceneLabel,
                                    isReady: providerStatus.sceneReady
                                )
                            }

                            LabeledContent("Depth candidate") {
                                HStack(spacing: 6) {
                                    if providerStatus.depthFormat != "Unknown" {
                                        Text(providerStatus.depthFormat)
                                            .foregroundStyle(.secondary)
                                    }
                                    providerReadinessLabel(
                                        providerStatus.depthLabel,
                                        isReady: providerStatus.depthReady
                                    )
                                }
                            }

                            LabeledContent("Motion candidate") {
                                HStack(spacing: 6) {
                                    if providerStatus.motionFormat != "Unknown" {
                                        Text(providerStatus.motionFormat)
                                            .foregroundStyle(.secondary)
                                    }
                                    providerReadinessLabel(
                                        providerStatus.motionLabel,
                                        isReady: providerStatus.motionReady
                                    )
                                }
                            }

                            if providerStatus.width > 0, providerStatus.height > 0 {
                                LabeledContent("Observed render size") {
                                    Text("\(providerStatus.width) × \(providerStatus.height)")
                                        .monospacedDigit()
                                }
                            }

                            Text(
                                providerStatus.rawExportReady
                                    ? "The renderer can export raw attachments to Metal. Native Temporal use remains locked until their meaning passes validation; Sol-model captures use only the truthful final-color stream."
                                    : "The renderer is still classifying native attachments. Until they validate, Spatial remains the safe runtime path and local captures can train the Sol model."
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Picker("Upscaling", selection: $settings.dlsmMode) {
                            ForEach(DLSMMode.allCases) { mode in
                                Text(mode.title)
                                    .tag(mode)
                                    .disabled(!supportsDLSMMode(mode))
                            }
                        }

                        Text(settings.dlsmMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Quality", selection: $settings.dlsmQuality) {
                            ForEach(DLSMQuality.allCases) { quality in
                                VStack(alignment: .leading) {
                                    Text(quality.title)
                                    Text(quality.scaleDescription)
                                }
                                .tag(quality)
                            }
                        }
                        .disabled(settings.dlsmMode == .off)

                        Toggle(
                            "Frame generation",
                            isOn: $settings.dlsmFrameGeneration
                        )
                        .disabled(
                            settings.dlsmMode != .temporal ||
                            !dlsmCapabilities.supportsFrameGeneration
                        )

                        if !dlsmCapabilities.hasNativeTemporalInputs {
                            Text(
                                "Frame generation unlocks only after depth, motion, and camera metadata pass native validation."
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !dlsmCapabilities.supportsFrameGenerationHardware {
                            Text("MetalFX frame generation requires macOS 26 and a supported Apple GPU.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Generates an intermediate MetalFX frame from DLSM history and motion data.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Label(
                            "DLSM changes apply the next time a game starts.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "Graphics Settings Unavailable",
                    systemImage: "display",
                    description: Text(configuration.lastError ?? "Build and embed the bundled native Sol Engine runtime.")
                )
            }
        }
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<SolEngineConfigurationStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { configuration[keyPath: keyPath] = $0 }
        )
    }

    private func integerSliderBinding(
        _ keyPath: ReferenceWritableKeyPath<SolEngineConfigurationStore, Int>
    ) -> Binding<Double> {
        Binding(
            get: { Double(configuration[keyPath: keyPath]) },
            set: { configuration[keyPath: keyPath] = Int($0.rounded()) }
        )
    }

    private func supportsDLSMMode(_ mode: DLSMMode) -> Bool {
        switch mode {
        case .off:
            true
        case .spatial:
            dlsmCapabilities.supportsSpatial
        case .temporal:
            dlsmCapabilities.supportsTemporal
        }
    }

    private func providerReadinessLabel(
        _ label: String,
        isReady: Bool
    ) -> some View {
        Label(
            label.capitalized,
            systemImage: isReady ? "checkmark.circle.fill" : "circle.dotted"
        )
        .foregroundStyle(isReady ? .green : .secondary)
    }
}

struct SolEngineAudioSettingsPane: View {
    @ObservedObject var configuration: SolEngineConfigurationStore

    var body: some View {
        Group {
            if configuration.isLoaded {
                Form {
                    Section("Output") {
                        Picker("Audio backend", selection: binding(\.audioBackend)) {
                            ForEach(SolEngineAudioBackend.allCases) { backend in
                                Text(backend.title).tag(backend)
                            }
                        }

                        LabeledContent("Volume") {
                            HStack {
                                Slider(value: binding(\.audioVolume), in: 0...1)
                                    .frame(width: 240)
                                Text(configuration.audioVolume, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "Audio Settings Unavailable",
                    systemImage: "speaker.wave.2",
                    description: Text(configuration.lastError ?? "Build and embed the bundled native Sol Engine runtime.")
                )
            }
        }
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<SolEngineConfigurationStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { configuration[keyPath: keyPath] = $0 }
        )
    }
}

struct SolEngineDeveloperSettingsPane: View {
    @ObservedObject var configuration: SolEngineConfigurationStore

    var body: some View {
        Group {
            if configuration.isLoaded {
                Form {
                    Section("Engine Logs") {
                        Toggle("Write logs to disk", isOn: binding(\.enableFileLog))

                        LabeledContent("Log folder") {
                            Button("Reveal") {
                                revealDirectory(named: "Logs")
                            }
                        }

                        DisclosureGroup("Log levels") {
                            Toggle("Debug", isOn: binding(\.loggingEnableDebug))
                            Toggle("Stub services", isOn: binding(\.loggingEnableStub))
                            Toggle("Information", isOn: binding(\.loggingEnableInfo))
                            Toggle("Warnings", isOn: binding(\.loggingEnableWarn))
                            Toggle("Errors", isOn: binding(\.loggingEnableError))
                            Toggle("Trace", isOn: binding(\.loggingEnableTrace))
                            Toggle("Guest logs", isOn: binding(\.loggingEnableGuest))
                            Toggle("Network logs", isOn: binding(\.loggingEnableNetwork))
                        }

                        Text("Debug and trace logging can reduce performance and create large files. Logs remain on this Mac and are never included in Sol Cloud.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("File-System Diagnostics") {
                        Toggle(
                            "Log guest file-system access",
                            isOn: binding(\.loggingEnableFSAccessLog)
                        )

                        Picker("Access-log detail", selection: binding(\.fsGlobalAccessLogMode)) {
                            Text("Off").tag(0)
                            Text("Errors").tag(1)
                            Text("Operations").tag(2)
                            Text("Verbose").tag(3)
                        }
                        .disabled(!configuration.loggingEnableFSAccessLog)

                        Toggle(
                            "Continue past missing guest services",
                            isOn: binding(\.ignoreMissingServices)
                        )

                        Label(
                            "Ignoring missing services is a compatibility diagnostic. It can hide an engine bug or change game behaviour.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    Section("Shader Capture") {
                        LabeledContent("Dump folder") {
                            HStack(spacing: 8) {
                                Text(
                                    configuration.graphicsShadersDumpPath.isEmpty
                                        ? "Disabled"
                                        : configuration.graphicsShadersDumpPath
                                )
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)

                                Button("Choose…", action: chooseShaderDumpDirectory)
                                if !configuration.graphicsShadersDumpPath.isEmpty {
                                    Button("Clear") {
                                        configuration.graphicsShadersDumpPath = ""
                                    }
                                }
                            }
                        }

                        Text("Shader dumps can be large and may contain title-specific material. Their location is device-specific and is not synced.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Guest Debugger") {
                        Toggle("Enable GDB stub", isOn: binding(\.enableGDBStub))

                        LabeledContent("Local port") {
                            TextField(
                                "Port",
                                value: binding(\.gdbStubPort),
                                format: .number.grouping(.never)
                            )
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .disabled(!configuration.enableGDBStub)
                        }

                        Toggle(
                            "Suspend guest on launch",
                            isOn: binding(\.debuggerSuspendOnStart)
                        )
                        .disabled(!configuration.enableGDBStub)

                        Label(
                            "Sol Engine binds GDB to 127.0.0.1 only. Changes take effect the next time a game starts.",
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let error = configuration.lastError {
                        Section("Configuration Error") {
                            Label(error, systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "Developer Settings Unavailable",
                    systemImage: "hammer",
                    description: Text("Start Sol Engine once to create its configuration file.")
                )
            }
        }
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<SolEngineConfigurationStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { configuration[keyPath: keyPath] = $0 }
        )
    }

    private func revealDirectory(named name: String) {
        guard let root = configuration.configURL?.deletingLastPathComponent() else { return }
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func chooseShaderDumpDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Shader Dump Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.graphicsShadersDumpPath = url.path
    }
}
