import Foundation
import Metal
import OSLog

/// Opt-in, local-only frame capture used to build the Sol Temporal dataset.
///
/// Capture is disabled unless `SOL_DLSM_CAPTURE_DIR` points at a directory.
/// The v2 format stores the exact quarter-resolution luminance consumed by the
/// model instead of full BGRA presentation frames. This makes adjacent-frame
/// capture practical without committing or transmitting game pixels.
final class DLSMTrainingCapture: @unchecked Sendable {
    private final class BufferBox: @unchecked Sendable {
        let buffer: any MTLBuffer

        init(_ buffer: any MTLBuffer) {
            self.buffer = buffer
        }
    }

    struct Metadata: Codable, Equatable {
        let schemaVersion: Int
        let sessionID: String
        let captureGroup: String
        let sequenceIndex: UInt64
        let frameID: UInt64
        let presentationTimestampNanoseconds: UInt64
        let sourceWidth: Int
        let sourceHeight: Int
        let width: Int
        let height: Int
        let bytesPerPixel: Int
        let pixelLayout: String
        let coarseScale: Int
        let captureInterval: UInt64
        let discontinuity: Bool
    }

    private struct Session {
        let identifier: String
        let captureGroup: String
        var scheduledCaptures: UInt64
    }

    private struct ScheduledCapture {
        let sessionID: String
        let captureGroup: String
        let sequenceIndex: UInt64
    }

    private static let coarseScale = 4

    private let directoryURL: URL
    private let interval: UInt64
    private let maximumFramesPerSession: UInt64
    private let logger = Logger(
        subsystem: "com.solemu.app",
        category: "DLSMTraining"
    )
    private let lock = NSLock()
    private let writerQueue = DispatchQueue(
        label: "com.solemu.dlsm.training-capture",
        qos: .utility
    )
    private let pendingWriteGroup = DispatchGroup()
    private var session: Session?
    private var pendingCaptures = 0
    private var writtenCaptures: [String: UInt64] = [:]
    private var capturePipeline: (any MTLComputePipelineState)?
    private var capturePipelineDeviceID: UInt64?

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DLSMTrainingCapture? {
        guard let path = environment["SOL_DLSM_CAPTURE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        let requestedInterval = UInt64(
            environment["SOL_DLSM_CAPTURE_INTERVAL"] ?? ""
        ) ?? 1
        let requestedMaximum = UInt64(
            environment["SOL_DLSM_CAPTURE_MAX_FRAMES"] ?? ""
        ) ?? 360
        return try? DLSMTrainingCapture(
            directoryURL: URL(fileURLWithPath: path, isDirectory: true),
            interval: max(1, requestedInterval),
            maximumFramesPerSession: max(2, requestedMaximum)
        )
    }

    init(
        directoryURL: URL,
        interval: UInt64,
        maximumFramesPerSession: UInt64 = 360
    ) throws {
        self.directoryURL = directoryURL
        self.interval = max(1, interval)
        self.maximumFramesPerSession = max(2, maximumFramesPerSession)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func beginSession(captureGroup: String?) {
        let group = Self.validatedCaptureGroup(captureGroup)
        let identifier = UUID().uuidString.lowercased()
        lock.withLock {
            session = Session(
                identifier: identifier,
                captureGroup: group,
                scheduledCaptures: 0
            )
        }
        logger.info(
            "Started local Sol-model capture session \(identifier, privacy: .public) for \(group, privacy: .private)"
        )
    }

    func endSession() {
        let completedSession = lock.withLock {
            let completedSession = session
            session = nil
            return completedSession
        }
        guard let completedSession else {
            return
        }
        logger.info(
            "Ended local Sol-model capture session \(completedSession.identifier, privacy: .public) after scheduling \(completedSession.scheduledCaptures, privacy: .public) frames"
        )
    }

    func encode(
        frameID: UInt64,
        presentationTimestampNanoseconds: UInt64,
        texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        discontinuity: Bool
    ) {
        guard frameID % interval == 0,
              texture.textureType == .type2D,
              texture.sampleCount == 1,
              texture.pixelFormat == .bgra8Unorm ||
                texture.pixelFormat == .bgra8Unorm_srgb,
              texture.usage.contains(.shaderRead) else {
            return
        }

        let scheduled: ScheduledCapture? = lock.withLock {
            guard var session,
                  session.scheduledCaptures < maximumFramesPerSession,
                  pendingCaptures < 3 else {
                return nil
            }
            session.scheduledCaptures += 1
            self.session = session
            pendingCaptures += 1
            return ScheduledCapture(
                sessionID: session.identifier,
                captureGroup: session.captureGroup,
                sequenceIndex: session.scheduledCaptures
            )
        }
        guard let scheduled else {
            return
        }
        pendingWriteGroup.enter()

        let captureWidth = max(
            1,
            (texture.width + Self.coarseScale - 1) / Self.coarseScale
        )
        let captureHeight = max(
            1,
            (texture.height + Self.coarseScale - 1) / Self.coarseScale
        )
        let bytesPerRow = Self.aligned(captureWidth, to: 256)
        guard let pipeline = capturePipeline(for: texture.device),
              let luminanceTexture = Self.makeLuminanceTexture(
                device: texture.device,
                width: captureWidth,
                height: captureHeight
              ),
              let buffer = texture.device.makeBuffer(
                length: bytesPerRow * captureHeight,
                options: .storageModeShared
              ),
              let compute = commandBuffer.makeComputeCommandEncoder() else {
            finishPendingCapture()
            pendingWriteGroup.leave()
            return
        }

        compute.label = "DLSM Sol Model Luminance Capture"
        compute.setComputePipelineState(pipeline)
        compute.setTexture(texture, index: 0)
        compute.setTexture(luminanceTexture, index: 1)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(
            1,
            pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        compute.dispatchThreads(
            MTLSize(width: captureWidth, height: captureHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
        compute.endEncoding()

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            finishPendingCapture()
            pendingWriteGroup.leave()
            return
        }
        blit.label = "DLSM Sol Model Capture Readback"
        blit.copy(
            from: luminanceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(
                width: captureWidth,
                height: captureHeight,
                depth: 1
            ),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * captureHeight
        )
        blit.endEncoding()

        let metadata = Metadata(
            schemaVersion: 2,
            sessionID: scheduled.sessionID,
            captureGroup: scheduled.captureGroup,
            sequenceIndex: scheduled.sequenceIndex,
            frameID: frameID,
            presentationTimestampNanoseconds:
                presentationTimestampNanoseconds,
            sourceWidth: texture.width,
            sourceHeight: texture.height,
            width: captureWidth,
            height: captureHeight,
            bytesPerPixel: 1,
            pixelLayout: "L8",
            coarseScale: Self.coarseScale,
            captureInterval: interval,
            discontinuity: discontinuity
        )
        let bufferBox = BufferBox(buffer)

        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            guard let self else { return }
            defer {
                self.finishPendingCapture()
            }
            guard completedBuffer.status == .completed else {
                self.pendingWriteGroup.leave()
                return
            }

            var compact = Data()
            compact.reserveCapacity(captureWidth * captureHeight)
            for row in 0..<captureHeight {
                compact.append(
                    bufferBox.buffer.contents()
                        .advanced(by: row * bytesPerRow)
                        .assumingMemoryBound(to: UInt8.self),
                    count: captureWidth
                )
            }
            let frameData = compact

            self.writerQueue.async {
                defer { self.pendingWriteGroup.leave() }
                self.write(frameData: frameData, metadata: metadata)
            }
        }
    }

    func flushWrites() {
        pendingWriteGroup.wait()
        writerQueue.sync {}
    }

    private func capturePipeline(
        for device: any MTLDevice
    ) -> (any MTLComputePipelineState)? {
        lock.withLock {
            if capturePipelineDeviceID == device.registryID {
                return capturePipeline
            }

            do {
                let library = try device.makeLibrary(
                    source: Self.shaderSource,
                    options: nil
                )
                guard let function = library.makeFunction(
                    name: "dlsmCaptureLuminance"
                ) else {
                    return nil
                }
                let pipeline = try device.makeComputePipelineState(
                    function: function
                )
                capturePipeline = pipeline
                capturePipelineDeviceID = device.registryID
                return pipeline
            } catch {
                logger.error(
                    "Could not compile the local Sol-model capture kernel: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    }

    private func finishPendingCapture() {
        lock.withLock {
            pendingCaptures = max(0, pendingCaptures - 1)
        }
    }

    private func write(frameData: Data, metadata: Metadata) {
        let stem = String(
            format: "frame-%@-%020llu",
            metadata.sessionID,
            metadata.sequenceIndex
        )
        let frameURL = directoryURL
            .appendingPathComponent(stem)
            .appendingPathExtension("luma")
        let metadataURL = directoryURL
            .appendingPathComponent(stem)
            .appendingPathExtension("json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try frameData.write(to: frameURL, options: .atomic)
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
            let count = lock.withLock {
                writtenCaptures[metadata.sessionID, default: 0] += 1
                return writtenCaptures[metadata.sessionID] ?? 0
            }
            if count == 1 || count % 120 == 0 {
                logger.info(
                    "Captured \(count, privacy: .public) adjacent Sol-model frames for session \(metadata.sessionID, privacy: .public)"
                )
            }
        } catch {
            logger.error(
                "Could not write a local Sol-model capture: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func makeLuminanceTexture(
        device: any MTLDevice,
        width: Int,
        height: Int
    ) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private static func validatedCaptureGroup(_ value: String?) -> String {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return "unlabeled"
        }
        return String(trimmed.prefix(128))
    }

    private static func aligned(_ value: Int, to alignment: Int) -> Int {
        ((value + alignment - 1) / alignment) * alignment
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void dlsmCaptureLuminance(
        texture2d<half, access::sample> source [[texture(0)]],
        texture2d<half, access::write> destination [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        const uint width = destination.get_width();
        const uint height = destination.get_height();
        if (gid.x >= width || gid.y >= height) {
            return;
        }

        constexpr sampler linearSampler(
            coord::normalized,
            address::clamp_to_edge,
            filter::linear
        );
        const float2 coordinate =
            (float2(gid) + 0.5) / float2(width, height);
        const float3 color = float3(
            source.sample(linearSampler, coordinate).rgb
        );
        const half luminance = half(
            dot(color, float3(0.2126, 0.7152, 0.0722))
        );
        destination.write(half4(luminance, 0.0, 0.0, 1.0), gid);
    }
    """
}
