import Foundation
import Metal
import MetalFX

enum DLSMFrameABI {
    static let version: UInt32 = 2
    static let minimumFrameSize: UInt32 = 144
}

struct DLSMFrameFlags: OptionSet, Sendable {
    let rawValue: UInt64

    static let color = DLSMFrameFlags(rawValue: 1 << 0)
    static let depth = DLSMFrameFlags(rawValue: 1 << 1)
    static let motion = DLSMFrameFlags(rawValue: 1 << 2)
    static let camera = DLSMFrameFlags(rawValue: 1 << 3)
    static let jitter = DLSMFrameFlags(rawValue: 1 << 4)
    static let discontinuity = DLSMFrameFlags(rawValue: 1 << 5)
    static let depthReversed = DLSMFrameFlags(rawValue: 1 << 6)

    static let nativeTemporalInputs: DLSMFrameFlags = [.depth, .motion]
}

enum DLSMTextureFormat: UInt32, Sendable {
    case unknown = 0
    case bgra8Unorm = 1
    case bgra8UnormSRGB = 2
    case r32Float = 3
    case rg16Float = 4
}

/// Stable C layout shared with `NativeEmbeddedEntrypoint.DlsmFrameInfoV2`.
///
/// Texture pointers are borrowed Objective-C Metal objects. They must first be
/// bridged during the synchronous callback. Sol may retain the active
/// swapchain objects only while that renderer session remains alive and must
/// release them before managed Vulkan teardown begins.
struct DLSMFrameInfoV2 {
    var abiVersion: UInt32
    var structSize: UInt32
    var frameID: UInt64
    var flagsRawValue: UInt64
    var metalCommandQueue: UnsafeMutableRawPointer?
    var colorTexture: UnsafeMutableRawPointer?
    var depthTexture: UnsafeMutableRawPointer?
    var motionTexture: UnsafeMutableRawPointer?
    var colorWidth: UInt32
    var colorHeight: UInt32
    var depthWidth: UInt32
    var depthHeight: UInt32
    var motionWidth: UInt32
    var motionHeight: UInt32
    var colorFormatRawValue: UInt32
    var depthFormatRawValue: UInt32
    var motionFormatRawValue: UInt32
    var reserved0: UInt32
    var motionVectorScaleX: Float
    var motionVectorScaleY: Float
    var jitterOffsetX: Float
    var jitterOffsetY: Float
    var nearPlane: Float
    var farPlane: Float
    var fieldOfViewDegrees: Float
    var aspectRatio: Float
    var deltaTimeSeconds: Float
    var reserved1: UInt32
    var presentationTimestampNanoseconds: UInt64

    var flags: DLSMFrameFlags {
        DLSMFrameFlags(rawValue: flagsRawValue)
    }

    var colorFormat: DLSMTextureFormat {
        DLSMTextureFormat(rawValue: colorFormatRawValue) ?? .unknown
    }

    var depthFormat: DLSMTextureFormat {
        DLSMTextureFormat(rawValue: depthFormatRawValue) ?? .unknown
    }

    var motionFormat: DLSMTextureFormat {
        DLSMTextureFormat(rawValue: motionFormatRawValue) ?? .unknown
    }

    var declaresNativeTemporalInputs: Bool {
        flags.contains(.nativeTemporalInputs)
    }

    var hasValidCameraMetadata: Bool {
        flags.contains(.camera) &&
            nearPlane.isFinite &&
            farPlane.isFinite &&
            fieldOfViewDegrees.isFinite &&
            aspectRatio.isFinite &&
            nearPlane > 0 &&
            farPlane > nearPlane &&
            fieldOfViewDegrees > 0 &&
            fieldOfViewDegrees < 180 &&
            aspectRatio > 0
    }

    static func decode(from rawPointer: UnsafeRawPointer) -> DLSMFrameInfoV2? {
        guard MemoryLayout<DLSMFrameInfoV2>.size == Int(DLSMFrameABI.minimumFrameSize),
              rawPointer.load(as: UInt32.self) == DLSMFrameABI.version,
              rawPointer.load(
                fromByteOffset: MemoryLayout<UInt32>.size,
                as: UInt32.self
              ) >= DLSMFrameABI.minimumFrameSize else {
            return nil
        }

        return rawPointer.load(as: DLSMFrameInfoV2.self)
    }
}

public enum DLSMMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case spatial
    case temporal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off:
            "Off"
        case .spatial:
            "Spatial"
        case .temporal:
            "Temporal"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            "Render directly through MoltenVK at the display resolution."
        case .spatial:
            "MetalFX machine-learning upscaling from a lower native render surface."
        case .temporal:
            "Temporal reconstruction through a trained Sol model or validated game-authored motion."
        }
    }
}

public enum DLSMQuality: String, CaseIterable, Identifiable, Sendable {
    case ultraQuality
    case quality
    case balanced
    case performance

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ultraQuality:
            "Ultra Quality"
        case .quality:
            "Quality"
        case .balanced:
            "Balanced"
        case .performance:
            "Performance"
        }
    }

    public var renderScale: Double {
        switch self {
        case .ultraQuality:
            0.77
        case .quality:
            0.67
        case .balanced:
            0.58
        case .performance:
            0.5
        }
    }

    public var scaleDescription: String {
        "\(Int((renderScale * 100).rounded()))% render resolution"
    }
}

public struct DLSMConfiguration: Equatable, Sendable {
    public var mode: DLSMMode
    public var quality: DLSMQuality
    public var frameGeneration: Bool

    public init(
        mode: DLSMMode,
        quality: DLSMQuality,
        frameGeneration: Bool
    ) {
        self.mode = mode
        self.quality = quality
        self.frameGeneration = frameGeneration
    }

    public var isEnabled: Bool {
        mode != .off
    }

    public func resolved(for capabilities: DLSMCapabilities) -> DLSMConfiguration {
        var resolved = self

        switch resolved.mode {
        case .off:
            resolved.frameGeneration = false
        case .spatial:
            if !capabilities.supportsSpatial {
                resolved.mode = .off
            }
            resolved.frameGeneration = false
        case .temporal:
            guard capabilities.supportsTemporal else {
                resolved.mode = capabilities.supportsSpatial ? .spatial : .off
                resolved.frameGeneration = false
                return resolved
            }
            resolved.frameGeneration =
                resolved.frameGeneration && capabilities.supportsFrameGeneration
        }

        return resolved
    }
}

public struct DLSMCapabilities: Sendable {
    public let gpuName: String
    public let supportsSpatial: Bool
    public let supportsTemporalHardware: Bool
    public let supportsFrameGenerationHardware: Bool
    public let hasNativeFrameBridge: Bool
    public let hasNativeTemporalInputs: Bool
    public let hasSolTemporalModel: Bool
    public let hasExperimentalReconstructedTemporalInputs: Bool
    public let allowsExperimentalTemporal: Bool

    public init(
        gpuName: String,
        supportsSpatial: Bool,
        supportsTemporalHardware: Bool,
        supportsFrameGenerationHardware: Bool,
        hasNativeFrameBridge: Bool,
        hasNativeTemporalInputs: Bool,
        hasSolTemporalModel: Bool,
        hasExperimentalReconstructedTemporalInputs: Bool = false,
        allowsExperimentalTemporal: Bool = false
    ) {
        self.gpuName = gpuName
        self.supportsSpatial = supportsSpatial
        self.supportsTemporalHardware = supportsTemporalHardware
        self.supportsFrameGenerationHardware = supportsFrameGenerationHardware
        self.hasNativeFrameBridge = hasNativeFrameBridge
        self.hasNativeTemporalInputs = hasNativeTemporalInputs
        self.hasSolTemporalModel = hasSolTemporalModel
        self.hasExperimentalReconstructedTemporalInputs =
            hasExperimentalReconstructedTemporalInputs
        self.allowsExperimentalTemporal = allowsExperimentalTemporal
    }

    public var supportsTemporal: Bool {
        supportsTemporalHardware &&
            (
                hasNativeTemporalInputs ||
                hasSolTemporalModel ||
                (
                    hasExperimentalReconstructedTemporalInputs &&
                    allowsExperimentalTemporal
                )
            )
    }

    public var supportsExperimentalTemporal: Bool {
        supportsTemporalHardware &&
            hasExperimentalReconstructedTemporalInputs
    }

    public var supportsFrameGeneration: Bool {
        supportsFrameGenerationHardware &&
            supportsTemporal &&
            hasNativeTemporalInputs
    }

    public static let current: DLSMCapabilities = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return DLSMCapabilities(
                gpuName: "No Metal GPU",
                supportsSpatial: false,
                supportsTemporalHardware: false,
                supportsFrameGenerationHardware: false,
                hasNativeFrameBridge: true,
                hasNativeTemporalInputs: false,
                hasSolTemporalModel: false,
                hasExperimentalReconstructedTemporalInputs: false,
                allowsExperimentalTemporal: false
            )
        }

        let frameGenerationHardware: Bool
        if #available(macOS 26.0, *) {
            frameGenerationHardware =
                MTLFXFrameInterpolatorDescriptor.supportsDevice(device)
        } else {
            frameGenerationHardware = false
        }

        return DLSMCapabilities(
            gpuName: device.name,
            supportsSpatial: MTLFXSpatialScalerDescriptor.supportsDevice(device),
            supportsTemporalHardware:
                MTLFXTemporalScalerDescriptor.supportsDevice(device),
            supportsFrameGenerationHardware: frameGenerationHardware,
            // ABI v2 can transport native auxiliary attachments, but SolEngine's
            // generic presenter currently has only final color. DLSM's Metal
            // The block-matching reconstruction provider remains available for
            // capture/research, but it no longer unlocks production Temporal:
            // pulsing UI and alpha effects can reuse invalid history. A trained
            // Sol provider or validated game-authored inputs must pass the gate.
            hasNativeFrameBridge: true,
            hasNativeTemporalInputs: false,
            hasSolTemporalModel:
                SolTemporalModel.preferred() != nil,
            hasExperimentalReconstructedTemporalInputs: true,
            allowsExperimentalTemporal:
                ProcessInfo.processInfo.environment[
                    "SOL_DLSM_ALLOW_EXPERIMENTAL_TEMPORAL"
                ] == "1"
        )
    }()
}
