import Metal

/// Canonical input contract for Temporal DLSM providers.
///
/// The experimental block matcher, bundled Sol-trained model, and replay
/// fixtures all produce the same Metal textures. Sol Engine and the app
/// therefore do not need to know which provider generated the motion and
/// confidence data.
protocol DLSMTemporalInputProvider: AnyObject {
    var identifier: String { get }

    func resetHistory()

    func encode(
        sourceTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        resetHistory: Bool
    ) -> DLSMReconstructedTemporalInputs?
}
