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
    private weak var metalView: MTKView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
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
    private var frameRequestGeneration: UInt64 = 0
    private var backgroundRequestGeneration: UInt64 = 0
    private var isStopped = false

    private var stateLock = os_unfair_lock_s()

    @MainActor init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.metalView = mtkView
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue

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

    @MainActor func start() {
        os_unfair_lock_lock(&stateLock)
        isStopped = false
        os_unfair_lock_unlock(&stateLock)
        requestFrames()
    }

    @MainActor func stop() {
        os_unfair_lock_lock(&stateLock)
        isStopped = true
        frameRequestGeneration &+= 1
        backgroundRequestGeneration &+= 1
        previousTexture = emptyTexture
        currentTexture = emptyTexture
        transitionProgress = 1
        hasBackground = 0
        os_unfair_lock_unlock(&stateLock)
        metalView?.isPaused = true
    }

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
        let changed = abs(targetFocus - focusIntensity) > 0.0005
            || abs(targetScroll - scrollOffset) > 0.25
            || simd_distance(targetFocusPoint, focusPoint) > 0.0005
            || abs(targetPerformance - performance) > 0.0005
        targetFocus = focusIntensity
        targetScroll = scrollOffset
        targetFocusPoint = focusPoint
        targetPerformance = performance
        os_unfair_lock_unlock(&stateLock)

        if changed {
            requestFrames()
        }
    }

    func updateBackground(image: NSImage?) {
        os_unfair_lock_lock(&stateLock)
        backgroundRequestGeneration &+= 1
        let requestGeneration = backgroundRequestGeneration
        let shouldLoad = !isStopped
        os_unfair_lock_unlock(&stateLock)

        guard shouldLoad else { return }
        textureQueue.async { [weak self] in
            guard let self else { return }

            autoreleasepool {
                if let image, let cgImage = image.cgImageForMetal() {
                    if let texture = self.makeBackgroundTexture(cgImage: cgImage) {
                        os_unfair_lock_lock(&self.stateLock)
                        let shouldApply = !self.isStopped
                            && self.backgroundRequestGeneration == requestGeneration
                        if shouldApply {
                            self.previousTexture = self.currentTexture
                            self.currentTexture = texture
                            self.transitionStart = CACurrentMediaTime()
                            self.transitionProgress = 0.0
                            self.hasBackground = 1.0
                        }
                        os_unfair_lock_unlock(&self.stateLock)
                        if shouldApply {
                            self.requestFrames()
                        }
                        return
                    }
                }

                os_unfair_lock_lock(&self.stateLock)
                let shouldApply = !self.isStopped
                    && self.backgroundRequestGeneration == requestGeneration
                if shouldApply {
                    self.previousTexture = self.currentTexture
                    self.currentTexture = self.emptyTexture
                    self.transitionStart = CACurrentMediaTime()
                    self.transitionProgress = 1.0
                    self.hasBackground = 0.0
                }
                os_unfair_lock_unlock(&self.stateLock)
                if shouldApply {
                    self.requestFrames()
                }
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        os_unfair_lock_lock(&stateLock)
        viewportSize = SIMD2<Float>(Float(size.width), Float(size.height))
        os_unfair_lock_unlock(&stateLock)
        requestFrames()
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
        let generation = frameRequestGeneration
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

        commandBuffer.label = "Sol Background Frame"
        encoder.label = "Sol Background Composite"

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 0)
        encoder.setFragmentTexture(currentTexture, index: 0)
        encoder.setFragmentTexture(previousTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        if transition >= 0.999 {
            os_unfair_lock_lock(&stateLock)
            if frameRequestGeneration == generation,
               transitionProgress >= 0.999 {
                // Once the crossfade completes, the old full-resolution
                // wallpaper no longer contributes to a frame. Release it
                // immediately instead of keeping two large Metal textures.
                self.previousTexture = emptyTexture
            }
            os_unfair_lock_unlock(&stateLock)
        }

        let needsMoreFrames = transition < 0.999
            || abs(focusTarget - smoothedFocus) > 0.001
            || abs(scrollTarget - smoothedScroll) > 0.1
            || simd_distance(focusPointTarget, smoothedFocusPoint) > 0.001
            || abs(performanceTarget - smoothedPerformance) > 0.001
        if !needsMoreFrames {
            pauseIfIdle(generation: generation)
        }
    }

    private func requestFrames() {
        os_unfair_lock_lock(&stateLock)
        frameRequestGeneration &+= 1
        let shouldStart = !isStopped
        os_unfair_lock_unlock(&stateLock)

        guard shouldStart else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let metalView = self.metalView else { return }
            os_unfair_lock_lock(&self.stateLock)
            let shouldStart = !self.isStopped
            os_unfair_lock_unlock(&self.stateLock)
            if shouldStart {
                metalView.isPaused = false
            }
        }
    }

    private func pauseIfIdle(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let metalView = self.metalView else { return }
            os_unfair_lock_lock(&self.stateLock)
            let shouldPause = !self.isStopped && self.frameRequestGeneration == generation
            os_unfair_lock_unlock(&self.stateLock)
            if shouldPause {
                metalView.isPaused = true
            }
        }
    }

    private func makeBackgroundTexture(cgImage: CGImage) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ),
              let bytes = context.data else {
            return nil
        }

        // ImageIO thumbnails can expose alpha-first pixels without an explicit
        // byte order. MTKTextureLoader then rotates those bytes (ARGB -> RGBA),
        // producing the purple/cyan cast seen on Home. Normalize every image to
        // a known sRGB BGRA layout before it crosses the Metal boundary.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.label = "Sol Background Artwork"
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    private static func makeEmptyTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
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
