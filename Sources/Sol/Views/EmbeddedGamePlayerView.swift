import AppKit
import Metal
import OSLog
import QuartzCore
import SolDLSM
import SwiftUI

struct EmbeddedGamePlayerView: NSViewRepresentable {
    @ObservedObject var viewModel: LauncherViewModel

    func makeNSView(context: Context) -> SolEngineRenderView {
        guard let view = viewModel.embeddedRenderView else {
            assertionFailure("Embedded render view requested without an active session")
            return SolEngineRenderView()
        }
        view.configureDLSM(viewModel.settings.dlsmConfiguration)
        view.prepareForAttachment()
        view.onReady = { [weak viewModel] renderView in
            // AppKit can attach the representable while SwiftUI is still
            // updating its graph. Defer the published launch-state changes to
            // the next main-run-loop turn.
            DispatchQueue.main.async { [weak viewModel, weak renderView] in
                guard let renderView else { return }
                viewModel?.attachEmbeddedRenderSurface(renderView)
            }
        }
        view.onLayout = { [weak viewModel] renderView in
            viewModel?.embeddedRenderSurfaceDidResize(renderView)
        }
        return view
    }

    func updateNSView(_ nsView: SolEngineRenderView, context: Context) {
        nsView.configureDLSM(viewModel.settings.dlsmConfiguration)
        nsView.notifyReadyIfPossible()
        viewModel.embeddedRenderSurfaceDidResize(nsView)
    }

    static func dismantleNSView(_ nsView: SolEngineRenderView, coordinator: ()) {
        nsView.retireAfterSession()
    }
}

final class SolEngineRenderView: NSView, CALayerDelegate {
    var onReady: ((SolEngineRenderView) -> Void)?
    var onLayout: ((SolEngineRenderView) -> Void)?
    var onKeyEvent: ((Int32, Bool) -> Void)?
    var onInputReset: (() -> Void)?
    private let sourceMetalLayer: CAMetalLayer
    private let outputMetalLayer: CAMetalLayer
    private let logger = Logger(subsystem: "com.solemu.app", category: "DLSM")
    let dlsmPipeline: SolDLSMPipeline
    private var requestedRenderPixelSize = CGSize(width: 1, height: 1)
    private var dlsmConfiguration = DLSMConfiguration(
        mode: .off,
        quality: .quality,
        frameGeneration: false
    )
    private var keyboardInputState = SolKeyboardInputStateTracker()
    private var didNotifyReady = false
    nonisolated(unsafe) private var windowResignObserver: NSObjectProtocol?
    nonisolated(unsafe) private var keyReleaseMonitor: Any?
#if DEBUG
    private var lastGeometryDescription = ""
#endif

    override init(frame frameRect: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        let sourceMetalLayer = CAMetalLayer()
        sourceMetalLayer.device = device
        sourceMetalLayer.pixelFormat = .bgra8Unorm
        sourceMetalLayer.framebufferOnly = false
        sourceMetalLayer.isOpaque = true
        sourceMetalLayer.backgroundColor = NSColor.black.cgColor
        sourceMetalLayer.maximumDrawableCount = 3
        sourceMetalLayer.allowsNextDrawableTimeout = true
        sourceMetalLayer.presentsWithTransaction = false
        sourceMetalLayer.zPosition = 0

        let outputMetalLayer = CAMetalLayer()
        outputMetalLayer.device = device
        outputMetalLayer.pixelFormat = .bgra8Unorm
        outputMetalLayer.framebufferOnly = false
        outputMetalLayer.isOpaque = true
        outputMetalLayer.backgroundColor = NSColor.black.cgColor
        outputMetalLayer.maximumDrawableCount = 3
        outputMetalLayer.allowsNextDrawableTimeout = true
        outputMetalLayer.presentsWithTransaction = false
        outputMetalLayer.zPosition = 1
        outputMetalLayer.isHidden = true

        self.sourceMetalLayer = sourceMetalLayer
        self.outputMetalLayer = outputMetalLayer
        self.dlsmPipeline = SolDLSMPipeline(outputLayer: outputMetalLayer)
        super.init(frame: frameRect)
        sourceMetalLayer.delegate = self
        outputMetalLayer.delegate = self
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        sourceMetalLayer.anchorPoint = .zero
        layer?.addSublayer(sourceMetalLayer)
        layer?.addSublayer(outputMetalLayer)
        dlsmPipeline.setPresentationAvailabilityHandler { [weak self] isAvailable in
            DispatchQueue.main.async { [weak self] in
                self?.setDLSMOutputAvailable(isAvailable)
            }
        }
        updateMetalLayerGeometry()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
        if let keyReleaseMonitor {
            NSEvent.removeMonitor(keyReleaseMonitor)
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        if let keyReleaseMonitor {
            NSEvent.removeMonitor(keyReleaseMonitor)
            self.keyReleaseMonitor = nil
        }
        if let window {
            windowResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resetInputState()
                }
            }
            // A rapid key chord can move first-responder ownership before the
            // render view receives the matching key-up. Observe releases at the
            // window boundary as a safety net; duplicate releases are collapsed
            // by SolKeyboardInputStateTracker.
            keyReleaseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyUp
            ) { [weak self, weak window] event in
                guard let self, event.window === window else { return event }
                self.forwardKey(event, pressed: false)
                return event
            }
        } else {
            resetInputState()
        }
        updateMetalLayerGeometry()
        notifyReadyIfPossible()
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            window?.makeKey()
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        resetInputState()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        forwardKey(event, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        forwardKey(event, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let scancode = Self.sdlScancode(for: event.keyCode) else {
            return
        }

        let pressed: Bool
        switch scancode {
        case 57:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            pressed = flags.contains(.capsLock)
        default:
            // AppKit exposes aggregate modifier flags, which cannot tell that
            // left Shift was released while right Shift remains down. Track
            // each physical modifier independently from its flagsChanged edge.
            pressed = !keyboardInputState.isPressed(keyCode: event.keyCode)
        }
        setKeyState(event.keyCode, scancode: scancode, pressed: pressed)
    }

    override func layout() {
        super.layout()
        updateMetalLayerGeometry()
        onLayout?(self)
    }

    override func makeBackingLayer() -> CALayer {
        // SDL wraps this NSView for input and focus, while Vulkan receives the
        // dedicated sourceMetalLayer pointer directly. A neutral AppKit
        // container keeps SDL/MoltenVK's fallback surface independent from
        // DLSM's full-resolution presentation layer.
        CALayer()
    }

    var metalLayer: CAMetalLayer? {
        sourceMetalLayer
    }

    var isDLSMEnabled: Bool {
        dlsmConfiguration.isEnabled
    }

    var dlsmCallbackContext: UnsafeMutableRawPointer {
        dlsmPipeline.callbackContext
    }

    var renderPixelSize: CGSize {
        requestedRenderPixelSize
    }

    var surfacePixelSize: CGSize {
        dlsmConfiguration.isEnabled
            ? requestedRenderPixelSize
            : outputMetalLayer.drawableSize
    }

    func configureDLSM(_ requestedConfiguration: DLSMConfiguration) {
        let configuration: DLSMConfiguration
        if DLSMFeatureGate.isEnabled {
            configuration = DLSMFeatureGate.resolvedConfiguration(
                requestedConfiguration,
                capabilities: .current
            )
        } else {
            configuration = DLSMFeatureGate.disabledConfiguration(
                preserving: requestedConfiguration
            )
        }

        guard dlsmConfiguration != configuration else {
            return
        }
        dlsmConfiguration = configuration
        if !configuration.isEnabled {
            setDLSMOutputAvailable(false)
        }
        updateMetalLayerGeometry()
    }

    private func setDLSMOutputAvailable(_ isAvailable: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The source layer remains the truthful fallback. Do not cover it with
        // a black or stale DLSM layer until Metal has completed an output frame.
        outputMetalLayer.isHidden = !dlsmConfiguration.isEnabled || !isAvailable
        CATransaction.commit()
    }

    func notifyReadyIfPossible() {
        guard !didNotifyReady,
              window != nil,
              SolEngineSurfaceSizing.logicalSize(
                  bounds: bounds.size,
                  window: window?.contentView?.bounds.size,
                  screen: window?.screen?.frame.size
              ) != nil else {
            return
        }
        didNotifyReady = true
        if dlsmConfiguration.isEnabled {
            logger.info(
                "DLSM surface ready at \(Int(self.requestedRenderPixelSize.width), privacy: .public)x\(Int(self.requestedRenderPixelSize.height), privacy: .public) -> \(Int(self.outputMetalLayer.drawableSize.width), privacy: .public)x\(Int(self.outputMetalLayer.drawableSize.height), privacy: .public)"
            )
        }
        onReady?(self)
    }

    func prepareForAttachment() {
        didNotifyReady = false
    }

    func fullscreenTransitionDidComplete() {
        // AppKit owns the fullscreen window frame. Refresh the borrowed Metal
        // layers only after its transition notification so SwiftUI's previous
        // safe-area proposal cannot leave a one-sided uncovered strip.
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateMetalLayerGeometry()
        onLayout?(self)
        window?.makeFirstResponder(self)
    }

    func retireAfterSession() {
        resetInputState()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        if let keyReleaseMonitor {
            NSEvent.removeMonitor(keyReleaseMonitor)
            self.keyReleaseMonitor = nil
        }
        onReady = nil
        onLayout = nil
        onKeyEvent = nil
        onInputReset = nil
        dlsmPipeline.setPresentationAvailabilityHandler(nil)
        setDLSMOutputAvailable(false)

        // Each launch intentionally owns a fresh swapchain layer. Once the
        // engine has terminated, detach the retired layers and their devices
        // so SwiftUI/AppKit view caching cannot keep old drawable pools alive.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sourceMetalLayer.delegate = nil
        outputMetalLayer.delegate = nil
        sourceMetalLayer.drawableSize = CGSize(width: 1, height: 1)
        outputMetalLayer.drawableSize = CGSize(width: 1, height: 1)
        sourceMetalLayer.removeFromSuperlayer()
        outputMetalLayer.removeFromSuperlayer()
        sourceMetalLayer.device = nil
        outputMetalLayer.device = nil
        CATransaction.commit()
    }

    private func forwardKey(_ event: NSEvent, pressed: Bool) {
        guard let scancode = Self.sdlScancode(for: event.keyCode) else {
            return
        }
        setKeyState(event.keyCode, scancode: scancode, pressed: pressed)
    }

    private func setKeyState(_ keyCode: UInt16, scancode: Int32, pressed: Bool) {
        for transition in keyboardInputState.update(
            keyCode: keyCode,
            scancode: scancode,
            pressed: pressed
        ) {
            onKeyEvent?(transition.scancode, transition.pressed)
        }
    }

    private func resetInputState() {
        keyboardInputState.reset()
        onInputReset?()
    }

    static func sdlScancode(for macVirtualKey: UInt16) -> Int32? {
        let index = Int(macVirtualKey)
        guard sdlScancodesByMacVirtualKey.indices.contains(index) else {
            return nil
        }
        let scancode = sdlScancodesByMacVirtualKey[index]
        return scancode == 0 ? nil : scancode
    }

    // Physical macOS virtual-key positions mapped to SDL3's USB scancodes.
    // This mirrors SDL's pinned scancodes_darwin table, so input is independent
    // of the active keyboard layout and matches SolEngine's physical-key config.
    private static let sdlScancodesByMacVirtualKey: [Int32] = [
        4, 22, 7, 9, 11, 10, 29, 27, 6, 25, 100, 5, 20, 26, 8, 21,
        28, 23, 30, 31, 32, 33, 35, 34, 46, 38, 36, 45, 37, 39, 48, 18,
        24, 47, 12, 19, 40, 15, 13, 52, 14, 51, 49, 54, 56, 17, 16, 55,
        43, 44, 53, 42, 88, 41, 231, 227, 225, 57, 226, 224, 229, 230, 228, 231,
        108, 99, 0, 85, 0, 87, 0, 83, 128, 129, 127, 84, 88, 0, 86, 109,
        110, 103, 98, 89, 90, 91, 92, 93, 94, 95, 0, 96, 97, 137, 135, 133,
        62, 63, 64, 60, 65, 66, 145, 68, 144, 70, 107, 71, 0, 67, 101, 69,
        0, 72, 73, 74, 75, 76, 61, 77, 59, 78, 58, 80, 79, 81, 82, 102,
    ]

    private func updateMetalLayerGeometry() {
        let isHostFullscreen = window?.styleMask.contains(.fullScreen) == true
        let presentationRect: CGRect
        if isHostFullscreen,
           let contentView = window?.contentView {
            // SwiftUI keeps NSViewRepresentable inside the display-cutout
            // safe rectangle in fullscreen. Present against the complete
            // window content rectangle so the guest image reaches every
            // display edge; conversion also handles a non-zero safe-area
            // origin on other MacBook display shapes.
            presentationRect = convert(contentView.bounds, from: contentView)
        } else {
            presentationRect = CGRect(origin: .zero, size: bounds.size)
        }

#if DEBUG
        let contentBounds = window?.contentView?.bounds ?? .zero
        let contentInsets = window?.contentView?.safeAreaInsets ?? .init()
        let geometryDescription = "fullscreen=\(isHostFullscreen) view=\(NSStringFromRect(bounds)) content=\(NSStringFromRect(contentBounds)) converted=\(NSStringFromRect(presentationRect)) safe=\(contentInsets.top),\(contentInsets.left),\(contentInsets.bottom),\(contentInsets.right)"
        if geometryDescription != lastGeometryDescription {
            lastGeometryDescription = geometryDescription
            logger.info("Render surface geometry: \(geometryDescription, privacy: .public)")
        }
#endif

        guard let logicalSize = SolEngineSurfaceSizing.logicalSize(
            bounds: presentationRect.size,
            window: window?.contentView?.bounds.size,
            screen: window?.screen?.frame.size
        ) else {
            return
        }

        let contentsScale = window?.backingScaleFactor ?? 1
        let backingSize = SolEngineSurfaceSizing.pixelSize(
            logical: logicalSize,
            scale: contentsScale
        )
        let renderScale = dlsmConfiguration.isEnabled
            ? dlsmConfiguration.quality.renderScale
            : 1
        requestedRenderPixelSize = SolEngineSurfaceSizing.pixelSize(
            logical: logicalSize,
            scale: contentsScale * renderScale
        )
        let sourceLogicalSize = CGSize(
            width: max(1, logicalSize.width * renderScale),
            height: max(1, logicalSize.height * renderScale)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        layer?.masksToBounds = !isHostFullscreen
        sourceMetalLayer.bounds = CGRect(origin: .zero, size: sourceLogicalSize)
        sourceMetalLayer.position = presentationRect.origin
        sourceMetalLayer.setAffineTransform(
            CGAffineTransform(scaleX: 1 / renderScale, y: 1 / renderScale)
        )
        sourceMetalLayer.contentsScale = contentsScale
        sourceMetalLayer.drawableSize = requestedRenderPixelSize

        let layerFrame = CGRect(origin: presentationRect.origin, size: logicalSize)
        outputMetalLayer.frame = layerFrame
        outputMetalLayer.contentsScale = contentsScale
        outputMetalLayer.drawableSize = CGSize(
            width: max(1, backingSize.width.rounded()),
            height: max(1, backingSize.height.rounded())
        )
        dlsmPipeline.configure(
            dlsmConfiguration,
            outputSize: outputMetalLayer.drawableSize
        )
    }
}

struct SolKeyboardInputTransition: Equatable {
    let scancode: Int32
    let pressed: Bool
}

struct SolKeyboardInputStateTracker {
    private var scancodeByKeyCode: [UInt16: Int32] = [:]

    var pressedScancodes: Set<Int32> {
        Set(scancodeByKeyCode.values)
    }

    func isPressed(keyCode: UInt16) -> Bool {
        scancodeByKeyCode[keyCode] != nil
    }

    mutating func update(
        keyCode: UInt16,
        scancode: Int32,
        pressed: Bool
    ) -> [SolKeyboardInputTransition] {
        if pressed {
            if scancodeByKeyCode[keyCode] == scancode {
                // Ignore AppKit key-repeat events. Sol Engine consumes current
                // state, not a queue of repeated key-down commands.
                return []
            }

            var transitions: [SolKeyboardInputTransition] = []
            if let previousScancode = scancodeByKeyCode.updateValue(
                scancode,
                forKey: keyCode
            ), !scancodeByKeyCode.values.contains(previousScancode) {
                transitions.append(
                    SolKeyboardInputTransition(
                        scancode: previousScancode,
                        pressed: false
                    )
                )
            }

            let duplicatePhysicalMapping = scancodeByKeyCode.contains { entry in
                entry.key != keyCode && entry.value == scancode
            }
            if !duplicatePhysicalMapping {
                transitions.append(
                    SolKeyboardInputTransition(scancode: scancode, pressed: true)
                )
            }
            return transitions
        }

        guard let releasedScancode = scancodeByKeyCode.removeValue(
            forKey: keyCode
        ) else {
            return []
        }

        guard !scancodeByKeyCode.values.contains(releasedScancode) else {
            return []
        }
        return [
            SolKeyboardInputTransition(
                scancode: releasedScancode,
                pressed: false
            )
        ]
    }

    mutating func reset() {
        scancodeByKeyCode.removeAll(keepingCapacity: true)
    }
}

enum SolEngineSurfaceSizing {
    static let minimumLogicalDimension: CGFloat = 64
    static let maximumPixelDimension: CGFloat = 8_192
    static let maximumPixelCount: CGFloat = 33_554_432

    static func logicalSize(
        bounds: CGSize,
        window: CGSize?,
        screen: CGSize?
    ) -> CGSize? {
        guard isUsableLogicalSize(bounds) else {
            return nil
        }

        var width = bounds.width
        var height = bounds.height

        for candidate in [window, screen].compactMap({ $0 }) where isUsableLogicalSize(candidate) {
            width = min(width, candidate.width)
            height = min(height, candidate.height)
        }

        let result = CGSize(width: width, height: height)
        return isUsableLogicalSize(result) ? result : nil
    }

    static func pixelSize(logical: CGSize, scale requestedScale: CGFloat) -> CGSize {
        let scale = requestedScale.isFinite && requestedScale > 0 ? requestedScale : 1
        var width = max(1, logical.width * scale)
        var height = max(1, logical.height * scale)

        let dimensionScale = min(
            1,
            maximumPixelDimension / max(width, height)
        )
        let pixelCount = width * height
        let areaScale = pixelCount > maximumPixelCount
            ? sqrt(maximumPixelCount / pixelCount)
            : 1
        let safetyScale = min(dimensionScale, areaScale)

        width = max(1, (width * safetyScale).rounded())
        height = max(1, (height * safetyScale).rounded())
        return CGSize(width: width, height: height)
    }

    static func validatedPixelSize(_ proposed: CGSize) -> CGSize? {
        guard proposed.width.isFinite,
              proposed.height.isFinite,
              proposed.width >= minimumLogicalDimension,
              proposed.height >= minimumLogicalDimension else {
            return nil
        }

        return pixelSize(logical: proposed, scale: 1)
    }

    private static func isUsableLogicalSize(_ size: CGSize) -> Bool {
        size.width.isFinite &&
            size.height.isFinite &&
            size.width >= minimumLogicalDimension &&
            size.height >= minimumLogicalDimension
    }
}
