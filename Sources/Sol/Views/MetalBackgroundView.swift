import SwiftUI
import AppKit
import Metal
import MetalKit

struct MetalBackgroundView: NSViewRepresentable {
    let viewSize: CGSize
    let focusIntensity: CGFloat
    let scrollOffset: CGFloat
    let focusPoint: CGPoint
    let backgroundImage: NSImage?
    let backgroundVersion: Int
    let isGamingMode: Bool
    let isLaunchActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return fallbackView()
        }

        let mtkView = PassthroughMTKView()
        mtkView.device = device
        mtkView.framebufferOnly = true
        mtkView.autoResizeDrawable = true
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.preferredFramesPerSecond = 60

        if let renderer = MetalRenderer(mtkView: mtkView) {
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
            renderer.start()
        } else {
            return fallbackView()
        }

        return mtkView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let mtkView = nsView as? MTKView else { return }

        let targetFps: Int
        if isLaunchActive {
            targetFps = 24
        } else if isGamingMode {
            targetFps = 36
        } else {
            targetFps = 60
        }
        if mtkView.preferredFramesPerSecond != targetFps {
            mtkView.preferredFramesPerSecond = targetFps
        }

        context.coordinator.renderer?.updateState(
            focusIntensity: Float(focusIntensity),
            scrollOffset: Float(scrollOffset),
            focusPoint: SIMD2<Float>(Float(focusPoint.x), Float(focusPoint.y)),
            isGamingMode: isGamingMode,
            isLaunchActive: isLaunchActive
        )

        if context.coordinator.lastBackgroundVersion != backgroundVersion {
            context.coordinator.lastBackgroundVersion = backgroundVersion
            context.coordinator.renderer?.updateBackground(image: backgroundImage)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let mtkView = nsView as? MTKView {
            mtkView.isPaused = true
            mtkView.delegate = nil
        }
        coordinator.renderer?.stop()
    }

    private func fallbackView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    final class Coordinator {
        var renderer: MetalRenderer?
        var lastBackgroundVersion: Int = -1
    }
}

private final class PassthroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }
}
