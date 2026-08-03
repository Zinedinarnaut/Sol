import Foundation

enum SolTemporalModelError: Error, Equatable, LocalizedError {
    case fileTooLarge
    case unsupportedSchema(Int)
    case unsupportedArchitecture(String)
    case invalidIdentifier
    case invalidCoarseScale(Int)
    case invalidMotionLimit
    case invalidWeightCount(name: String, expected: Int, actual: Int)
    case invalidWeightValue(name: String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "The Sol Temporal model is larger than the supported one-megabyte limit."
        case let .unsupportedSchema(version):
            "Sol Temporal model schema \(version) is not supported."
        case let .unsupportedArchitecture(architecture):
            "Sol Temporal model architecture \(architecture) is not supported."
        case .invalidIdentifier:
            "The Sol Temporal model identifier is invalid."
        case let .invalidCoarseScale(scale):
            "Sol Temporal model scale \(scale) is not supported."
        case .invalidMotionLimit:
            "The Sol Temporal model motion limit is invalid."
        case let .invalidWeightCount(name, expected, actual):
            "Sol Temporal model tensor \(name) expected \(expected) values, not \(actual)."
        case let .invalidWeightValue(name):
            "Sol Temporal model tensor \(name) contains an invalid value."
        }
    }
}

/// A compact, versioned Sol-trained motion-and-reactive model.
///
/// A validated candidate ships inside SolDLSM, while an explicit local path
/// can override it for evaluation. A malformed or incompatible override never
/// unlocks Temporal DLSM or silently substitutes the bundled model.
struct SolTemporalModel: Sendable {
    static let schemaVersion = 1
    static let architecture = "sol-flow-reactive-2x3x3-v1"
    static let coarseScale = 4
    static let maximumArtifactBytes = 1_048_576

    static let conv1WeightCount = 8 * 3 * 3 * 4
    static let conv1BiasCount = 8
    static let conv2WeightCount = 3 * 3 * 3 * 8
    static let conv2BiasCount = 3

    let identifier: String
    let motionLimit: Float
    let conv1Weights: [Float]
    let conv1Bias: [Float]
    let conv2Weights: [Float]
    let conv2Bias: [Float]

    static func load(from url: URL) throws -> SolTemporalModel {
        let data = try Data(
            contentsOf: url,
            options: [.mappedIfSafe, .uncached]
        )
        return try decode(data: data)
    }

    static func decode(data: Data) throws -> SolTemporalModel {
        guard data.count <= maximumArtifactBytes else {
            throw SolTemporalModelError.fileTooLarge
        }

        let artifact = try JSONDecoder().decode(Artifact.self, from: data)
        guard artifact.schemaVersion == schemaVersion else {
            throw SolTemporalModelError.unsupportedSchema(
                artifact.schemaVersion
            )
        }
        guard artifact.architecture == architecture else {
            throw SolTemporalModelError.unsupportedArchitecture(
                artifact.architecture
            )
        }
        guard isValidIdentifier(artifact.identifier) else {
            throw SolTemporalModelError.invalidIdentifier
        }
        guard artifact.coarseScale == coarseScale else {
            throw SolTemporalModelError.invalidCoarseScale(
                artifact.coarseScale
            )
        }
        guard artifact.motionLimit.isFinite,
              artifact.motionLimit >= 1,
              artifact.motionLimit <= 32 else {
            throw SolTemporalModelError.invalidMotionLimit
        }

        try validate(
            artifact.weights.conv1,
            name: "conv1",
            expectedCount: conv1WeightCount
        )
        try validate(
            artifact.weights.conv1Bias,
            name: "conv1Bias",
            expectedCount: conv1BiasCount
        )
        try validate(
            artifact.weights.conv2,
            name: "conv2",
            expectedCount: conv2WeightCount
        )
        try validate(
            artifact.weights.conv2Bias,
            name: "conv2Bias",
            expectedCount: conv2BiasCount
        )

        return SolTemporalModel(
            identifier: artifact.identifier,
            motionLimit: artifact.motionLimit,
            conv1Weights: artifact.weights.conv1,
            conv1Bias: artifact.weights.conv1Bias,
            conv2Weights: artifact.weights.conv2,
            conv2Bias: artifact.weights.conv2Bias
        )
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SolTemporalModel? {
        guard let path = environment["SOL_DLSM_MODEL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        return try? load(from: URL(fileURLWithPath: path))
    }

    static func preferred(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SolTemporalModel? {
        if let requestedPath = environment["SOL_DLSM_MODEL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedPath.isEmpty {
            // An explicit but invalid candidate must fail closed instead of
            // silently substituting a different model.
            return try? load(
                from: URL(fileURLWithPath: requestedPath)
            )
        }
        return bundledCandidate()
    }

    private static func bundledCandidate() -> SolTemporalModel? {
        let bundle: Bundle
        #if SWIFT_PACKAGE
        bundle = .module
        #else
        bundle = Bundle(for: DLSMFrameworkBundleToken.self)
        #endif

        for resource in ["sol-temporal-v1", "sol-temporal-v0"] {
            guard let url = bundle.url(
                forResource: resource,
                withExtension: "json"
            ) else {
                continue
            }
            if let model = try? load(from: url) {
                return model
            }
        }
        return nil
    }

    private static func isValidIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= 64 else {
            return false
        }

        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        return identifier.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validate(
        _ values: [Float],
        name: String,
        expectedCount: Int
    ) throws {
        guard values.count == expectedCount else {
            throw SolTemporalModelError.invalidWeightCount(
                name: name,
                expected: expectedCount,
                actual: values.count
            )
        }
        guard values.allSatisfy({
            $0.isFinite && abs($0) <= 256
        }) else {
            throw SolTemporalModelError.invalidWeightValue(name: name)
        }
    }

    private struct Artifact: Decodable {
        let schemaVersion: Int
        let identifier: String
        let architecture: String
        let coarseScale: Int
        let motionLimit: Float
        let weights: Weights
    }

    private struct Weights: Decodable {
        let conv1: [Float]
        let conv1Bias: [Float]
        let conv2: [Float]
        let conv2Bias: [Float]
    }
}

private final class DLSMFrameworkBundleToken {}
