import Foundation
import AppKit
import Metal
import MetalKit
import simd
import os

struct MetalUniforms {
    var time: Float
    var focusIntensity: Float
    var scrollOffset: Float
    var transition: Float
    var resolution: SIMD2<Float>
    var focusPoint: SIMD2<Float>
    var hasBackground: Float
    var performance: Float
}

final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textureLoader: MTKTextureLoader
    private let textureQueue = DispatchQueue(label: "solEngine.metal.textures", qos: .userInitiated)

    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var viewportSize = SIMD2<Float>(0, 0)

    private var targetFocus: Float = 0.0
    private var targetScroll: Float = 0.0
    private var smoothedFocus: Float = 0.0
    private var smoothedScroll: Float = 0.0

    private var targetFocusPoint = SIMD2<Float>(0.5, 0.6)
    private var smoothedFocusPoint = SIMD2<Float>(0.5, 0.6)

    private var targetPerformance: Float = 1.0
    private var smoothedPerformance: Float = 1.0

    private var emptyTexture: MTLTexture
    private var currentTexture: MTLTexture
    private var previousTexture: MTLTexture
    private var transitionStart: CFTimeInterval = 0
    private var transitionDuration: CFTimeInterval = 0.65
    private var transitionProgress: Float = 1.0
    private var hasBackground: Float = 0.0

    private var stateLock = os_unfair_lock_s()

    @MainActor init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue
        self.textureLoader = MTKTextureLoader(device: device)

        guard let emptyTexture = MetalRenderer.makeEmptyTexture(device: device) else { return nil }
        self.emptyTexture = emptyTexture
        self.currentTexture = emptyTexture
        self.previousTexture = emptyTexture

        let library: MTLLibrary?
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "BackgroundShader", withExtension: "metal") {
            library = try? device.makeLibrary(URL: url)
        } else {
            library = device.makeDefaultLibrary()
        }
        #else
        library = device.makeDefaultLibrary()
        #endif

        guard let vertexFunction = library?.makeFunction(name: "vertex_main"),
              let fragmentFunction = library?.makeFunction(name: "fragment_main") else {
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "SolBackgroundPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            return nil
        }

        super.init()

        self.viewportSize = SIMD2<Float>(Float(mtkView.drawableSize.width), Float(mtkView.drawableSize.height))
    }

    @MainActor func start() {}
    @MainActor func stop() {}

    func updateState(
        focusIntensity: Float,
        scrollOffset: Float,
        focusPoint: SIMD2<Float>,
        isGamingMode: Bool,
        isLaunchActive: Bool
    ) {
        let performance: Float
        if isLaunchActive {
            performance = 0.45
        } else if isGamingMode {
            performance = 0.7
        } else {
            performance = 1.0
        }

        os_unfair_lock_lock(&stateLock)
        targetFocus = focusIntensity
        targetScroll = scrollOffset
        targetFocusPoint = focusPoint
        targetPerformance = performance
        os_unfair_lock_unlock(&stateLock)
    }

    func updateBackground(image: NSImage?) {
        textureQueue.async { [weak self] in
            guard let self else { return }

            let newTexture: MTLTexture
            if let image, let cgImage = image.cgImageForMetal() {
                let options: [MTKTextureLoader.Option: Any] = [
                    .SRGB: false,
                    .origin: MTKTextureLoader.Origin.flippedVertically
                ]
                if let texture = try? self.textureLoader.newTexture(cgImage: cgImage, options: options) {
                    newTexture = texture
                    os_unfair_lock_lock(&self.stateLock)
                    self.previousTexture = self.currentTexture
                    self.currentTexture = newTexture
                    self.transitionStart = CACurrentMediaTime()
                    self.transitionProgress = 0.0
                    self.hasBackground = 1.0
                    os_unfair_lock_unlock(&self.stateLock)
                    return
                }
            }

            os_unfair_lock_lock(&self.stateLock)
            self.previousTexture = self.currentTexture
            self.currentTexture = self.emptyTexture
            self.transitionStart = CACurrentMediaTime()
            self.transitionProgress = 0.0
            self.hasBackground = 0.0
            os_unfair_lock_unlock(&self.stateLock)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        os_unfair_lock_lock(&stateLock)
        viewportSize = SIMD2<Float>(Float(size.width), Float(size.height))
        os_unfair_lock_unlock(&stateLock)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        render(drawable: drawable, descriptor: descriptor)
    }

    private func render(drawable: CAMetalDrawable, descriptor: MTLRenderPassDescriptor) {
        let now = CACurrentMediaTime()
        let time = Float(now - startTime)

        os_unfair_lock_lock(&stateLock)
        let focusTarget = targetFocus
        let scrollTarget = targetScroll
        let resolution = viewportSize
        let focusPointTarget = targetFocusPoint
        let performanceTarget = targetPerformance
        let hasBackground = self.hasBackground
        let previousTexture = self.previousTexture
        let currentTexture = self.currentTexture
        let transitionStart = self.transitionStart
        let transitionDuration = self.transitionDuration
        var transition = self.transitionProgress
        os_unfair_lock_unlock(&stateLock)

        if transition < 1.0 {
            let progress = Float(min(1.0, (now - transitionStart) / transitionDuration))
            transition = progress
            os_unfair_lock_lock(&stateLock)
            self.transitionProgress = progress
            os_unfair_lock_unlock(&stateLock)
        }

        smoothedFocus += (focusTarget - smoothedFocus) * 0.12
        smoothedScroll += (scrollTarget - smoothedScroll) * 0.12
        smoothedFocusPoint += (focusPointTarget - smoothedFocusPoint) * 0.15
        smoothedPerformance += (performanceTarget - smoothedPerformance) * 0.12

        var uniforms = MetalUniforms(
            time: time,
            focusIntensity: smoothedFocus,
            scrollOffset: smoothedScroll,
            transition: transition,
            resolution: resolution,
            focusPoint: smoothedFocusPoint,
            hasBackground: hasBackground,
            performance: smoothedPerformance
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 0)
        encoder.setFragmentTexture(currentTexture, index: 0)
        encoder.setFragmentTexture(previousTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makeEmptyTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel: [UInt8] = [8, 8, 8, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return texture
    }
}

private extension NSImage {
    func cgImageForMetal() -> CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
