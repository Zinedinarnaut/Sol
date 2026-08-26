import SwiftUI
import AppKit

struct ControllerManagerView: View {
    @ObservedObject var viewModel: ControllerManagerViewModel
    @ObservedObject var launcherViewModel: LauncherViewModel
    @State private var selectedBackendInputID: String?
    @State private var selectedPlayer = SolEnginePlayerIndex.player1
    @State private var backendSelectionWasUserChosen = false
    @State private var detailMode = ControllerDetailMode.bindings

    var body: some View {
        VStack(spacing: 0) {
            backendInputRouting

            Picker("Controller Settings", selection: $detailMode) {
                Label("Bindings", systemImage: "switch.2").tag(ControllerDetailMode.bindings)
                Label("Hardware", systemImage: "gamecontroller").tag(ControllerDetailMode.hardware)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
            .padding(.bottom, 10)

            Divider()

            if detailMode == .bindings {
                mappingDetails
            } else {
                hardwareDetails
            }
        }
        .onAppear {
            viewModel.setNavigationEnabled(false)
            launcherViewModel.refreshBackendInputs()
        }
        .onDisappear {
            viewModel.setNavigationEnabled(true)
        }
        .onChange(of: launcherViewModel.backendInputDevices, initial: true) { _, devices in
            reconcileBackendSelection(in: devices)
        }
        .onChange(of: selectedPlayer) { _, _ in
            backendSelectionWasUserChosen = false
            reconcileBackendSelection(in: launcherViewModel.backendInputDevices)
        }
        .onChange(of: viewModel.selectedControllerID) { _, _ in
            guard !backendSelectionWasUserChosen else { return }
            reconcileBackendSelection(in: launcherViewModel.backendInputDevices)
        }
    }

    @ViewBuilder
    private var mappingDetails: some View {
        if let mapping = selectedControllerMapping {
            Form {
                Section("Button Mapping") {
                    ControllerMappingEditor(
                        mapping: mapping,
                        input: selectedHardwareController?.input ?? ControllerInputSnapshot(),
                        isDualSense: selectedHardwareController?.supportsDualSense
                            ?? mapping.inputName.localizedCaseInsensitiveContains("DualSense"),
                        canRecord: selectedHardwareController != nil,
                        isSaving: launcherViewModel.isBackendOperationRunning,
                        onChange: { control, button in
                            launcherViewModel.setControllerBinding(
                                button,
                                for: control,
                                player: selectedPlayer
                            )
                        },
                        onReset: {
                            launcherViewModel.resetControllerBindings(for: selectedPlayer)
                        }
                    )
                    .id("\(mapping.player.rawValue)-\(mapping.inputID)")
                }

                Section("Stick, Motion & Feedback") {
                    ControllerTuningEditor(
                        tuning: mapping.tuning,
                        canTestRumble: selectedBackendDevice?.isConnected == true,
                        isSaving: launcherViewModel.isBackendOperationRunning,
                        onSave: { tuning in
                            launcherViewModel.saveControllerTuning(
                                tuning,
                                for: selectedPlayer
                            )
                        },
                        onTestRumble: {
                            launcherViewModel.testControllerRumble(for: selectedPlayer)
                        }
                    )
                    .id("\(mapping.player.rawValue)-\(mapping.inputID)-tuning")
                }
            }
            .formStyle(.grouped)
        } else if launcherViewModel.isBackendOperationRunning {
            ContentUnavailableView {
                Label("Loading Bindings", systemImage: "switch.2")
            } description: {
                Text("Reading \(selectedPlayer.title)’s controller layout from Sol Engine.")
            } actions: {
                ProgressView()
                    .controlSize(.small)
            }
        } else {
            ContentUnavailableView(
                "No Controller Mapping",
                systemImage: "switch.2",
                description: Text("Assign a controller to \(selectedPlayer.title) to create its button layout.")
            )
        }
    }

    @ViewBuilder
    private var hardwareDetails: some View {
        if viewModel.controllers.isEmpty {
            ContentUnavailableView(
                "No Controllers Connected",
                systemImage: "gamecontroller",
                description: Text("Wake or connect a controller to inspect live input, haptics, and hardware features. Saved bindings remain available in the Bindings tab.")
            )
        } else {
            NavigationSplitView {
                List(selection: selectedControllerID) {
                    ForEach(viewModel.controllers) { controller in
                        ControllerRow(controller: controller)
                            .tag(controller.id)
                    }
                }
                .navigationTitle("Controllers")
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            } detail: {
                controllerDetails
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var backendInputRouting: some View {
        GroupBox("Player Input") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Device")

                    if launcherViewModel.backendInputDevices.isEmpty {
                        Text(
                            launcherViewModel.isBackendOperationRunning
                                ? "Detecting Sol Engine devices…"
                                : "No Sol Engine input devices found"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        Picker("Device", selection: backendInputSelection) {
                            ForEach(launcherViewModel.backendInputDevices) { device in
                                Label(device.pickerTitle, systemImage: device.kind.systemImage)
                                    .tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                    }

                    Button {
                        launcherViewModel.refreshBackendInputs()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(backendActionsDisabled)
                }

                GridRow {
                    Text("Player")

                    Picker("Player", selection: $selectedPlayer) {
                        ForEach(SolEnginePlayerIndex.allCases) { player in
                            Text(player.title).tag(player)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180, alignment: .leading)

                    Button(assignmentButtonTitle) {
                        confirmAndAssignBackendInput()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        selectedBackendDevice == nil ||
                        selectedBackendDevice?.isConnected == false ||
                        selectedBackendDevice?.isAssigned(to: selectedPlayer) == true ||
                        backendActionsDisabled
                    )
                }
            }

            Text("Choose the physical controller Sol Engine should send to each player. Connected controllers are preferred automatically; choose All keyboards only when you want keyboard controls.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 10)
    }

    private var backendInputSelection: Binding<String> {
        Binding(
            get: { selectedBackendInputID ?? launcherViewModel.backendInputDevices.first?.id ?? "" },
            set: {
                selectedBackendInputID = $0
                backendSelectionWasUserChosen = true
            }
        )
    }

    private var selectedBackendDevice: SolEngineInputDevice? {
        guard let selectedBackendInputID else { return nil }
        return launcherViewModel.backendInputDevices.first(where: { $0.id == selectedBackendInputID })
    }

    private var backendActionsDisabled: Bool {
        launcherViewModel.isBackendOperationRunning || launcherViewModel.isLaunching
    }

    private var assignmentButtonTitle: String {
        if selectedBackendDevice?.isAssigned(to: selectedPlayer) == true {
            return "Assigned to \(selectedPlayer.title)"
        }
        return "Assign to \(selectedPlayer.title)"
    }

    private func reconcileBackendSelection(in devices: [SolEngineInputDevice]) {
        selectedBackendInputID = SolEngineInputSelection.preferredDeviceID(
            in: devices,
            for: selectedPlayer,
            matching: viewModel.selectedController?.name,
            currentID: selectedBackendInputID,
            preserveCurrent: backendSelectionWasUserChosen
        )
    }

    private func confirmAndAssignBackendInput() {
        guard let device = selectedBackendDevice else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Assign \(device.name) to \(selectedPlayer.title)?"
        alert.informativeText = "This replaces \(selectedPlayer.title)’s current input mapping with Sol Engine’s default \(device.kind.title.lowercased()) layout."
        alert.addButton(withTitle: "Assign")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        launcherViewModel.assignInputDevice(device, to: selectedPlayer)
    }

    private var selectedControllerID: Binding<UUID?> {
        Binding(
            get: { viewModel.selectedControllerID },
            set: { id in
                guard let id else { return }
                viewModel.selectController(id)
            }
        )
    }

    @ViewBuilder
    private var controllerDetails: some View {
        if let controller = viewModel.selectedController {
            Form {
                Section("Controller") {
                    LabeledContent("Name", value: controller.name)
                    LabeledContent("Vendor", value: controller.vendorName ?? "Unknown")
                    LabeledContent("Category", value: controller.productCategory)
                    LabeledContent("Status") {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if controller.isAttachedToDevice {
                        LabeledContent("Device style", value: "Integrated")
                    }

                    if let level = controller.batteryLevel {
                        LabeledContent("Battery") {
                            Text("\(Int(level * 100))% \(controller.batteryState ?? "")")
                                .monospacedDigit()
                        }
                    }
                }

                Section("Live Input") {
                    ControllerInputGrid(
                        input: controller.input,
                        supportsDualSense: controller.supportsDualSense
                    )
                }

                Section("Haptics") {
                    if controller.supportsHaptics {
                        DoubleSliderRow(
                            title: "Intensity",
                            value: $viewModel.hapticIntensity,
                            range: 0...1
                        )
                        DoubleSliderRow(
                            title: "Sharpness",
                            value: $viewModel.hapticSharpness,
                            range: 0...1
                        )
                        DoubleSliderRow(
                            title: "Duration",
                            value: $viewModel.hapticDuration,
                            range: 0.1...1.5,
                            suffix: " s"
                        )

                        HStack {
                            Spacer()
                            Button("Play Haptic") {
                                viewModel.playHaptics()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Text("This controller does not expose haptic controls.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Lightbar") {
                    if controller.supportsLight {
                        ColorPicker(
                            "Color",
                            selection: $viewModel.lightbarColor,
                            supportsOpacity: false
                        )

                        HStack {
                            Spacer()
                            Button("Apply Color") {
                                viewModel.setLightbarColor()
                            }
                        }
                    } else {
                        Text("This controller does not expose a lightbar.")
                            .foregroundStyle(.secondary)
                    }
                }

                if controller.supportsDualSense {
                    Section("Left Adaptive Trigger") {
                        DualSenseTriggerControls(settings: $viewModel.leftTriggerSettings) {
                            viewModel.applyLeftTrigger()
                        }
                    }

                    Section("Right Adaptive Trigger") {
                        DualSenseTriggerControls(settings: $viewModel.rightTriggerSettings) {
                            viewModel.applyRightTrigger()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(controller.name)
        } else {
            ContentUnavailableView(
                "Select a Controller",
                systemImage: "gamecontroller",
                description: Text("Choose a connected controller from the sidebar.")
            )
        }
    }

    private var selectedControllerMapping: SolEngineControllerMapping? {
        guard let mapping = launcherViewModel.backendControllerMappings[selectedPlayer],
              mapping.inputID == selectedBackendInputID else {
            return nil
        }
        return mapping
    }

    private var selectedHardwareController: ControllerInfo? {
        guard let mapping = selectedControllerMapping else { return nil }

        if let matching = viewModel.controllers.first(where: {
            $0.name.localizedCaseInsensitiveCompare(mapping.inputName) == .orderedSame
        }) {
            return matching
        }

        return viewModel.controllers.count == 1 ? viewModel.controllers.first : nil
    }
}

private enum ControllerDetailMode: Hashable {
    case bindings
    case hardware
}

private extension SolEngineInputDevice.Kind {
    var systemImage: String {
        switch self {
        case .keyboard: return "keyboard"
        case .controller: return "gamecontroller"
        }
    }
}

private extension SolEngineInputDevice {
    var pickerTitle: String {
        var details: [String] = []
        if let assignmentTitle {
            details.append(assignmentTitle)
        }
        if !isConnected {
            details.append("Disconnected")
        }
        guard !details.isEmpty else { return name }
        return "\(name) — \(details.joined(separator: ", "))"
    }
}

private struct ControllerRow: View {
    let controller: ControllerInfo

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.name)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(controller.productCategory)

                    if let level = controller.batteryLevel {
                        Text("•")
                        Text("\(Int(level * 100))%")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } icon: {
            Image(systemName: controller.supportsDualSense ? "gamecontroller.fill" : "gamecontroller")
        }
    }
}

private struct ControllerInputGrid: View {
    let input: ControllerInputSnapshot
    let supportsDualSense: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            inputRow("Left stick", value: "\(format(input.leftStickX)), \(format(input.leftStickY))")
            inputRow("Right stick", value: "\(format(input.rightStickX)), \(format(input.rightStickY))")
            inputRow("D-Pad", value: "\(format(input.dpadX)), \(format(input.dpadY))")
            inputRow(
                "Triggers",
                value: supportsDualSense
                    ? "L2 \(format(input.leftTrigger))  R2 \(format(input.rightTrigger))"
                    : "L \(format(input.leftTrigger))  R \(format(input.rightTrigger))"
            )
            inputRow(
                "Face buttons",
                value: supportsDualSense
                    ? "Cross \(state(input.buttonA))  Circle \(state(input.buttonB))  Square \(state(input.buttonX))  Triangle \(state(input.buttonY))"
                    : "A \(state(input.buttonA))  B \(state(input.buttonB))  X \(state(input.buttonX))  Y \(state(input.buttonY))"
            )
            inputRow(
                "Shoulders",
                value: supportsDualSense
                    ? "L1 \(state(input.leftShoulder))  R1 \(state(input.rightShoulder))"
                    : "L \(state(input.leftShoulder))  R \(state(input.rightShoulder))"
            )
            inputRow(
                "System",
                value: supportsDualSense
                    ? "Options \(state(input.buttonMenu))  Create \(state(input.buttonOptions))  PS \(state(input.buttonHome))"
                    : "Menu \(state(input.buttonMenu))  Options \(state(input.buttonOptions))  Home \(state(input.buttonHome))"
            )
            inputRow(
                "Stick buttons",
                value: supportsDualSense
                    ? "L3 \(state(input.leftThumbstickButton))  R3 \(state(input.rightThumbstickButton))"
                    : "Left \(state(input.leftThumbstickButton))  Right \(state(input.rightThumbstickButton))"
            )

            if supportsDualSense {
                inputRow("Touchpad", value: state(input.touchpadButton))
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }

    private func inputRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
    }

    private func format(_ value: Float) -> String {
        String(format: "%+.2f", value)
    }

    private func state(_ value: Bool) -> String {
        value ? "On" : "Off"
    }
}

private struct ControllerMappingEditor: View {
    let mapping: SolEngineControllerMapping
    let input: ControllerInputSnapshot
    let isDualSense: Bool
    let canRecord: Bool
    let isSaving: Bool
    let onChange: (SolEngineLogicalControl, SolEnginePhysicalButton) -> Void
    let onReset: () -> Void

    @State private var listeningControl: SolEngineLogicalControl?
    @State private var captureBaseline = ControllerInputSnapshot()
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Game controls are on the left and the physical controller buttons are on the right. Changes save directly to Sol Engine.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !canRecord {
                Label(
                    "Controller is disconnected. You can use the menus now, or wake it to record buttons directly.",
                    systemImage: "moon.zzz"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            mappingGroup("Face Buttons", controls: SolEngineLogicalControl.faceButtons)
            Divider()
            mappingGroup("Shoulders", controls: SolEngineLogicalControl.shoulderButtons)
            Divider()
            mappingGroup("System", controls: SolEngineLogicalControl.systemButtons)
            Divider()
            mappingGroup("D-Pad", controls: SolEngineLogicalControl.directionalButtons)

            if let listeningControl {
                Label(
                    "Press a controller button for \(listeningControl.title)…",
                    systemImage: "record.circle"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.tint)
            } else if isSaving {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving controller mapping…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label(mapping.inputName, systemImage: "gamecontroller")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button("Restore Recommended Layout") {
                    showResetConfirmation = true
                }
                .disabled(isSaving)
            }
        }
        .onChange(of: input) { _, newInput in
            guard let listeningControl else { return }

            if let button = newInput.newlyPressedPhysicalButton(comparedTo: captureBaseline) {
                self.listeningControl = nil
                onChange(listeningControl, button)
            } else {
                captureBaseline = newInput
            }
        }
        .confirmationDialog(
            "Restore the recommended layout for \(mapping.player.title)?",
            isPresented: $showResetConfirmation
        ) {
            Button("Restore Layout") {
                listeningControl = nil
                onReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the custom button mapping for \(mapping.player.title).")
        }
    }

    private func mappingGroup(
        _ title: String,
        controls: [SolEngineLogicalControl]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(controls) { control in
                LabeledContent(control.title) {
                    HStack(spacing: 8) {
                        Picker(control.title, selection: binding(for: control)) {
                            ForEach(SolEnginePhysicalButton.allCases) { button in
                                Text(button.title(isDualSense: isDualSense))
                                    .tag(button)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 175)
                        .disabled(isSaving || listeningControl != nil)

                        Button {
                            if listeningControl == control {
                                listeningControl = nil
                            } else {
                                captureBaseline = input
                                listeningControl = control
                            }
                        } label: {
                            Image(
                                systemName: listeningControl == control
                                    ? "xmark.circle.fill"
                                    : "record.circle"
                            )
                        }
                        .buttonStyle(.borderless)
                        .disabled(isSaving || !canRecord)
                        .help(
                            !canRecord
                                ? "Wake or connect the controller to record a button"
                                : listeningControl == control
                                ? "Cancel button capture"
                                : "Press a controller button to set \(control.title)"
                        )
                        .accessibilityLabel(
                            listeningControl == control
                                ? "Cancel button capture"
                                : "Record \(control.title)"
                        )
                    }
                }
            }
        }
    }

    private func binding(for control: SolEngineLogicalControl) -> Binding<SolEnginePhysicalButton> {
        Binding(
            get: { mapping.bindings[control] ?? .unbound },
            set: { onChange(control, $0) }
        )
    }
}

private struct ControllerTuningEditor: View {
    let tuning: SolEngineControllerTuning
    let canTestRumble: Bool
    let isSaving: Bool
    let onSave: (SolEngineControllerTuning) -> Void
    let onTestRumble: () -> Void

    @State private var draft: SolEngineControllerTuning

    init(
        tuning: SolEngineControllerTuning,
        canTestRumble: Bool,
        isSaving: Bool,
        onSave: @escaping (SolEngineControllerTuning) -> Void,
        onTestRumble: @escaping () -> Void
    ) {
        self.tuning = tuning
        self.canTestRumble = canTestRumble
        self.isSaving = isSaving
        self.onSave = onSave
        self.onTestRumble = onTestRumble
        _draft = State(initialValue: tuning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                tuningSlider("Left stick deadzone", value: $draft.deadzoneLeft, range: 0...0.5)
                tuningSlider("Right stick deadzone", value: $draft.deadzoneRight, range: 0...0.5)
                tuningSlider("Left stick range", value: $draft.rangeLeft, range: 0.5...1.5)
                tuningSlider("Right stick range", value: $draft.rangeRight, range: 0.5...1.5)
                tuningSlider("Trigger threshold", value: $draft.triggerThreshold, range: 0...1)
            }

            Divider()

            Toggle("Motion controls", isOn: $draft.motionEnabled)
            if draft.motionEnabled {
                LabeledContent("Motion sensitivity") {
                    HStack(spacing: 8) {
                        Slider(value: motionSensitivity, in: 1...200, step: 1)
                            .frame(minWidth: 180)
                        Text("\(draft.motionSensitivity)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                tuningSlider("Gyro deadzone", value: $draft.gyroDeadzone, range: 0...10)
            }

            Divider()

            Toggle("Game rumble", isOn: $draft.rumbleEnabled)
            if draft.rumbleEnabled {
                tuningSlider("Strong motor", value: $draft.strongRumble, range: 0...1)
                tuningSlider("Weak motor", value: $draft.weakRumble, range: 0...1)
                Toggle("HD rumble when supported", isOn: $draft.hdRumble)
            }

            Divider()

            Toggle("Let Sol control the controller light", isOn: $draft.ledEnabled)
            if draft.ledEnabled {
                Toggle("Turn light off", isOn: $draft.ledOff)
                Toggle("Rainbow effect", isOn: $draft.ledRainbow)
                    .disabled(draft.ledOff)
                ColorPicker(
                    "Light color",
                    selection: ledColor,
                    supportsOpacity: false
                )
                .disabled(draft.ledOff || draft.ledRainbow)
            }

            HStack {
                Text("These values are saved in Sol Engine and apply in games.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Test Rumble") {
                    onTestRumble()
                }
                .disabled(isSaving || !canTestRumble)
                .help(
                    canTestRumble
                        ? "Play a short rumble on the assigned controller"
                        : "Wake or connect the assigned controller first"
                )

                Button("Save Tuning") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || draft == tuning)
            }
        }
        .onChange(of: tuning) { _, newValue in
            guard !isSaving else { return }
            draft = newValue
        }
    }

    private var motionSensitivity: Binding<Double> {
        Binding(
            get: { Double(draft.motionSensitivity) },
            set: { draft.motionSensitivity = Int($0.rounded()) }
        )
    }

    private var ledColor: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: Double((draft.ledColor >> 16) & 0xFF) / 255,
                    green: Double((draft.ledColor >> 8) & 0xFF) / 255,
                    blue: Double(draft.ledColor & 0xFF) / 255
                )
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                let red = UInt32((converted.redComponent * 255).rounded())
                let green = UInt32((converted.greenComponent * 255).rounded())
                let blue = UInt32((converted.blueComponent * 255).rounded())
                draft.ledColor = (red << 16) | (green << 8) | blue
            }
        )
    }

    private func tuningSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range)
                    .frame(minWidth: 180)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }
}

private struct DoubleSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range)
                    .frame(minWidth: 180)
                Text("\(value, format: .number.precision(.fractionLength(2)))\(suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

private struct DualSenseTriggerControls: View {
    @Binding var settings: DualSenseTriggerSettings
    let onApply: () -> Void

    var body: some View {
        Picker("Mode", selection: $settings.mode) {
            ForEach(DualSenseTriggerMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }

        if settings.mode == .feedback {
            sliderRow("Start", value: $settings.startPosition)
            sliderRow("Strength", value: $settings.strength)
        } else if settings.mode == .weapon {
            sliderRow("Start", value: $settings.startPosition)
            sliderRow("End", value: $settings.endPosition)
            sliderRow("Strength", value: $settings.strength)
        } else if settings.mode == .vibration {
            sliderRow("Start", value: $settings.startPosition)
            sliderRow("Amplitude", value: $settings.amplitude)
            sliderRow("Frequency", value: $settings.frequency)
        } else if settings.mode == .slopeFeedback {
            sliderRow("Start", value: $settings.startPosition)
            sliderRow("End", value: $settings.endPosition)
            sliderRow("Start strength", value: $settings.startStrength)
            sliderRow("End strength", value: $settings.endStrength)
        }

        HStack {
            Spacer()
            Button("Apply Trigger") {
                onApply()
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Float>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: 0...1)
                    .frame(minWidth: 180)
                Text(String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }
}
