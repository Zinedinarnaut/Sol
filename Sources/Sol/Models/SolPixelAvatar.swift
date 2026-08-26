import Foundation

enum SolProfileAvatarSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case pixel
    case custom
    case apple
    case gameProfile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pixel: "Sol Pixel"
        case .custom: "Custom Image"
        case .apple: "Apple Account"
        case .gameProfile: "Game Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .pixel: "square.grid.3x3.square"
        case .custom: "photo"
        case .apple: "apple.logo"
        case .gameProfile: "person.crop.circle"
        }
    }
}

enum SolPixelAvatarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case solar
    case aurora
    case ocean
    case ember
    case violet
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solar: "Solar"
        case .aurora: "Aurora"
        case .ocean: "Ocean"
        case .ember: "Ember"
        case .violet: "Violet"
        case .graphite: "Graphite"
        }
    }
}

struct SolPixelAvatar: Codable, Equatable, Hashable, Identifiable, Sendable {
    let seed: UInt64
    let style: SolPixelAvatarStyle

    var id: String {
        "\(style.rawValue)-\(seed)"
    }

    static func stableDefault(profileID: UUID) -> SolPixelAvatar {
        SolPixelAvatar(
            seed: stableSeed(profileID.uuidString),
            style: .solar
        )
    }

    static func candidates(
        style: SolPixelAvatarStyle,
        baseSeed: UInt64,
        count: Int = 12
    ) -> [SolPixelAvatar] {
        guard count > 0 else { return [] }

        let styleSeed = stableSeed(style.rawValue)
        var state = mix(baseSeed ^ styleSeed)
        return (0..<count).map { index in
            state = mix(state &+ UInt64(index) &+ 0x9E37_79B9_7F4A_7C15)
            return SolPixelAvatar(
                seed: state & UInt64(Int64.max),
                style: style
            )
        }
    }

    private static func stableSeed(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return mix(hash) & UInt64(Int64.max)
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var mixed = value
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
