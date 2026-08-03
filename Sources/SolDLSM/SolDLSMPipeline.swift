import Foundation
import QuartzCore

private typealias SolDLSMPresentCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeRawPointer?
) -> Int32

private let solDLSMPresentCallback: SolDLSMPresentCallback = {
    context,
    framePointer in
    guard let context,
          let framePointer,
          let frame = DLSMFrameInfoV2.decode(from: framePointer) else {
        return 0
    }

    let pipeline = Unmanaged<SolDLSMPipeline>
        .fromOpaque(context)
        .takeUnretainedValue()
    return pipeline.present(frame: frame) ? 1 : 0
}

/// Public boundary between Sol Engine's frame provider and the native
/// Metal/MetalFX DLSM implementation.
///
/// Sol owns this object for the lifetime of one render view. Sol Engine receives
/// only the callback and context pointers, while frame decoding, reconstruction,
/// scaling, history, and presentation remain private to this library.
public final class SolDLSMPipeline: @unchecked Sendable {
    private let processor: DLSMProcessor

    public init(outputLayer: CAMetalLayer) {
        processor = DLSMProcessor(outputLayer: outputLayer)
    }

    public var isEnabled: Bool {
        processor.isEnabled
    }

    public var diagnostics: DLSMDiagnostics {
        processor.diagnostics
    }

    /// Function pointer passed to Sol Engine's native DLSM callback slot.
    public var callbackPointer: UnsafeMutableRawPointer {
        unsafeBitCast(
            solDLSMPresentCallback,
            to: UnsafeMutableRawPointer.self
        )
    }

    /// Stable, unretained context pointer paired with `callbackPointer`.
    public var callbackContext: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    public func beginSession(captureGroup: String? = nil) {
        processor.beginSession(captureGroup: captureGroup)
    }

    public func endSession() {
        processor.endSession()
    }

    public func configure(
        _ configuration: DLSMConfiguration,
        outputSize: CGSize
    ) {
        processor.configure(configuration, outputSize: outputSize)
    }

    fileprivate func present(frame: DLSMFrameInfoV2) -> Bool {
        processor.present(frame: frame)
    }
}
