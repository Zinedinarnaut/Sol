import XCTest
@testable import SolDLSM

final class DLSMConfigurationTests: XCTestCase {
    func testPublicLaunchKeepsDLSMDisabled() {
        let requested = DLSMConfiguration(
            mode: .temporal,
            quality: .performance,
            frameGeneration: true
        )

        let resolved = DLSMFeatureGate.resolvedConfiguration(
            requested,
            capabilities: capabilities(hasNativeTemporalInputs: true),
            environment: [:]
        )

        XCTAssertEqual(
            resolved,
            DLSMConfiguration(
                mode: .off,
                quality: .performance,
                frameGeneration: false
            )
        )
    }

    func testDeveloperLaunchCanEnableDLSM() {
        let requested = DLSMConfiguration(
            mode: .spatial,
            quality: .quality,
            frameGeneration: true
        )

        let resolved = DLSMFeatureGate.resolvedConfiguration(
            requested,
            capabilities: capabilities(hasNativeTemporalInputs: false),
            environment: [DLSMFeatureGate.environmentKey: "1"]
        )

        XCTAssertEqual(
            resolved,
            DLSMConfiguration(
                mode: .spatial,
                quality: .quality,
                frameGeneration: false
            )
        )
    }

    func testQualityModesReducePresentationResolutionInOrder() {
        let scales = DLSMQuality.allCases.map(\.renderScale)

        XCTAssertEqual(scales, [0.77, 0.67, 0.58, 0.5])
        XCTAssertEqual(scales, scales.sorted(by: >))
        XCTAssertTrue(scales.allSatisfy { $0 > 0 && $0 < 1 })
    }

    func testOnlyUpscalingModesEnableDLSM() {
        XCTAssertFalse(
            DLSMConfiguration(
                mode: .off,
                quality: .quality,
                frameGeneration: false
            ).isEnabled
        )
        XCTAssertTrue(
            DLSMConfiguration(
                mode: .spatial,
                quality: .quality,
                frameGeneration: false
            ).isEnabled
        )
        XCTAssertTrue(
            DLSMConfiguration(
                mode: .temporal,
                quality: .quality,
                frameGeneration: true
            ).isEnabled
        )
    }

    func testTemporalFallsBackToSpatialWithoutNativeTemporalInputs() {
        let requested = DLSMConfiguration(
            mode: .temporal,
            quality: .quality,
            frameGeneration: true
        )

        XCTAssertEqual(
            requested.resolved(for: capabilities(hasNativeTemporalInputs: false)),
            DLSMConfiguration(
                mode: .spatial,
                quality: .quality,
                frameGeneration: false
            )
        )
    }

    func testTemporalAndFrameGenerationRemainAvailableWithNativeInputs() {
        let requested = DLSMConfiguration(
            mode: .temporal,
            quality: .balanced,
            frameGeneration: true
        )

        XCTAssertEqual(
            requested.resolved(for: capabilities(hasNativeTemporalInputs: true)),
            requested
        )
    }

    func testExperimentalReconstructionDoesNotUnlockProductionTemporal() {
        let requested = DLSMConfiguration(
            mode: .temporal,
            quality: .balanced,
            frameGeneration: true
        )

        XCTAssertEqual(
            requested.resolved(
                for: capabilities(
                    hasNativeTemporalInputs: false,
                    hasExperimentalReconstructedTemporalInputs: true
                )
            ),
            DLSMConfiguration(
                mode: .spatial,
                quality: .balanced,
                frameGeneration: false
            )
        )
    }

    func testTrainedSolModelUnlocksTemporalButNotFrameGeneration() {
        let requested = DLSMConfiguration(
            mode: .temporal,
            quality: .balanced,
            frameGeneration: true
        )

        XCTAssertEqual(
            requested.resolved(
                for: capabilities(
                    hasNativeTemporalInputs: false,
                    hasSolTemporalModel: true
                )
            ),
            DLSMConfiguration(
                mode: .temporal,
                quality: .balanced,
                frameGeneration: false
            )
        )
    }

    func testDeveloperFlagCanUnlockExperimentalTemporalWithoutFrameGeneration() {
        let requested = DLSMConfiguration(
            mode: .temporal,
            quality: .performance,
            frameGeneration: true
        )

        XCTAssertEqual(
            requested.resolved(
                for: capabilities(
                    hasNativeTemporalInputs: false,
                    hasExperimentalReconstructedTemporalInputs: true,
                    allowsExperimentalTemporal: true
                )
            ),
            DLSMConfiguration(
                mode: .temporal,
                quality: .performance,
                frameGeneration: false
            )
        )
    }

    func testSpatialNeverCarriesFrameGeneration() {
        let requested = DLSMConfiguration(
            mode: .spatial,
            quality: .performance,
            frameGeneration: true
        )

        XCTAssertEqual(
            requested.resolved(for: capabilities(hasNativeTemporalInputs: true)),
            DLSMConfiguration(
                mode: .spatial,
                quality: .performance,
                frameGeneration: false
            )
        )
    }

    func testNativeFrameABIV2HasStableCLayout() {
        XCTAssertEqual(DLSMFrameABI.version, 2)
        XCTAssertEqual(MemoryLayout<DLSMFrameInfoV2>.size, 144)
        XCTAssertEqual(MemoryLayout<DLSMFrameInfoV2>.stride, 144)
        XCTAssertEqual(MemoryLayout<DLSMFrameInfoV2>.alignment, 8)
        XCTAssertEqual(MemoryLayout.offset(of: \DLSMFrameInfoV2.frameID), 8)
        XCTAssertEqual(MemoryLayout.offset(of: \DLSMFrameInfoV2.flagsRawValue), 16)
        XCTAssertEqual(MemoryLayout.offset(of: \DLSMFrameInfoV2.metalCommandQueue), 24)
        XCTAssertEqual(MemoryLayout.offset(of: \DLSMFrameInfoV2.colorTexture), 32)
        XCTAssertEqual(MemoryLayout.offset(of: \DLSMFrameInfoV2.depthTexture), 40)
        XCTAssertEqual(MemoryLayout.offset(of: \DLSMFrameInfoV2.motionTexture), 48)
        XCTAssertEqual(MemoryLayout.offset(of: \DLSMFrameInfoV2.motionVectorScaleX), 96)
        XCTAssertEqual(
            MemoryLayout.offset(of: \DLSMFrameInfoV2.presentationTimestampNanoseconds),
            136
        )
    }

    func testNativeFrameDecoderRejectsWrongVersionAndTruncatedFrames() {
        var valid = frameInfo()
        XCTAssertNotNil(withUnsafePointer(to: &valid) {
            DLSMFrameInfoV2.decode(from: UnsafeRawPointer($0))
        })

        var wrongVersion = frameInfo(version: 1)
        XCTAssertNil(withUnsafePointer(to: &wrongVersion) {
            DLSMFrameInfoV2.decode(from: UnsafeRawPointer($0))
        })

        var truncated = frameInfo(structSize: 8)
        XCTAssertNil(withUnsafePointer(to: &truncated) {
            DLSMFrameInfoV2.decode(from: UnsafeRawPointer($0))
        })
    }

    func testTemporalAndCameraMetadataAreDeclaredIndependently() {
        let temporalOnly = frameInfo(flags: [.color, .depth, .motion])
        XCTAssertTrue(temporalOnly.declaresNativeTemporalInputs)
        XCTAssertFalse(temporalOnly.hasValidCameraMetadata)

        let complete = frameInfo(
            flags: [.color, .depth, .motion, .camera],
            nearPlane: 0.1,
            farPlane: 1_000,
            fieldOfViewDegrees: 60,
            aspectRatio: 16.0 / 9.0
        )
        XCTAssertTrue(complete.declaresNativeTemporalInputs)
        XCTAssertTrue(complete.hasValidCameraMetadata)

        let invalidFrustum = frameInfo(
            flags: [.color, .depth, .motion, .camera],
            nearPlane: 10,
            farPlane: 1,
            fieldOfViewDegrees: 60,
            aspectRatio: 16.0 / 9.0
        )
        XCTAssertFalse(invalidFrustum.hasValidCameraMetadata)
    }

    private func capabilities(
        hasNativeTemporalInputs: Bool,
        hasSolTemporalModel: Bool = false,
        hasExperimentalReconstructedTemporalInputs: Bool = false,
        allowsExperimentalTemporal: Bool = false
    ) -> DLSMCapabilities {
        DLSMCapabilities(
            gpuName: "Test GPU",
            supportsSpatial: true,
            supportsTemporalHardware: true,
            supportsFrameGenerationHardware: true,
            hasNativeFrameBridge: true,
            hasNativeTemporalInputs: hasNativeTemporalInputs,
            hasSolTemporalModel: hasSolTemporalModel,
            hasExperimentalReconstructedTemporalInputs:
                hasExperimentalReconstructedTemporalInputs,
            allowsExperimentalTemporal: allowsExperimentalTemporal
        )
    }

    private func frameInfo(
        version: UInt32 = DLSMFrameABI.version,
        structSize: UInt32 = DLSMFrameABI.minimumFrameSize,
        flags: DLSMFrameFlags = [.color],
        nearPlane: Float = 0,
        farPlane: Float = 0,
        fieldOfViewDegrees: Float = 0,
        aspectRatio: Float = 0
    ) -> DLSMFrameInfoV2 {
        DLSMFrameInfoV2(
            abiVersion: version,
            structSize: structSize,
            frameID: 1,
            flagsRawValue: flags.rawValue,
            metalCommandQueue: nil,
            colorTexture: nil,
            depthTexture: nil,
            motionTexture: nil,
            colorWidth: 1280,
            colorHeight: 720,
            depthWidth: 1280,
            depthHeight: 720,
            motionWidth: 1280,
            motionHeight: 720,
            colorFormatRawValue: DLSMTextureFormat.bgra8Unorm.rawValue,
            depthFormatRawValue: DLSMTextureFormat.r32Float.rawValue,
            motionFormatRawValue: DLSMTextureFormat.rg16Float.rawValue,
            reserved0: 0,
            motionVectorScaleX: 1,
            motionVectorScaleY: 1,
            jitterOffsetX: 0,
            jitterOffsetY: 0,
            nearPlane: nearPlane,
            farPlane: farPlane,
            fieldOfViewDegrees: fieldOfViewDegrees,
            aspectRatio: aspectRatio,
            deltaTimeSeconds: 1.0 / 60.0,
            reserved1: 0,
            presentationTimestampNanoseconds: 1
        )
    }
}
