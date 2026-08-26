import AppKit
import CoreGraphics

@MainActor
final class SolPixelAvatarRenderer {
    static let shared = SolPixelAvatarRenderer()

    private let cache = NSCache<NSString, NSImage>()
    private let logicalSize = 24

    func image(
        for avatar: SolPixelAvatar,
        dimension requestedDimension: Int = 240
    ) -> NSImage {
        let pixelScale = max(requestedDimension / logicalSize, 1)
        let dimension = logicalSize * pixelScale
        let key = "\(avatar.id)-\(dimension)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let rendered = render(avatar, dimension: dimension, pixelScale: pixelScale)
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    func pngData(
        for avatar: SolPixelAvatar,
        dimension: Int = 240
    ) -> Data? {
        guard let tiff = image(for: avatar, dimension: dimension).tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }

    private func render(
        _ avatar: SolPixelAvatar,
        dimension: Int,
        pixelScale: Int
    ) -> NSImage {
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: NSSize(width: dimension, height: dimension))
        }

        context.setShouldAntialias(false)
        context.interpolationQuality = .none

        var generator = PixelGenerator(seed: avatar.seed ^ styleSalt(avatar.style))
        let palette = palette(for: avatar.style)
        let skinIndex = generator.nextIndex(min(skinTones.count, skinShadows.count))
        let skin = skinTones[skinIndex]
        let skinShadow = skinShadows[skinIndex]
        let hair = hairColors[generator.nextIndex(hairColors.count)]
        let eye = eyeColors[generator.nextIndex(eyeColors.count)]
        let hairStyle = generator.nextIndex(5)
        let backgroundPattern = generator.nextIndex(4)
        let accessory = generator.nextIndex(5)

        func fill(
            _ x: Int,
            _ y: Int,
            _ width: Int = 1,
            _ height: Int = 1,
            _ color: CGColor
        ) {
            context.setFillColor(color)
            context.fill(
                CGRect(
                    x: x * pixelScale,
                    y: (logicalSize - y - height) * pixelScale,
                    width: width * pixelScale,
                    height: height * pixelScale
                )
            )
        }

        fill(0, 0, logicalSize, logicalSize, palette.background)
        drawBackground(
            pattern: backgroundPattern,
            palette: palette,
            fill: fill
        )

        // Shoulders, shirt, and neck.
        fill(9, 15, 6, 4, skinShadow)
        fill(5, 19, 14, 5, palette.clothing)
        fill(7, 17, 10, 7, palette.clothing)
        fill(10, 18, 4, 2, palette.clothingAccent)
        if generator.nextBool() {
            fill(5, 22, 14, 2, palette.clothingAccent)
        } else {
            fill(11, 18, 2, 6, palette.clothingAccent)
        }

        // Face and ears.
        fill(6, 9, 2, 5, skinShadow)
        fill(16, 9, 2, 5, skinShadow)
        fill(7, 5, 10, 11, skin)
        fill(7, 13, 2, 3, skinShadow)
        fill(15, 13, 2, 3, skinShadow)

        drawHair(style: hairStyle, color: hair, fill: fill)

        // Brows, eyes, nose, and mouth.
        fill(9, 9, 2, 1, hair)
        fill(13, 9, 2, 1, hair)
        fill(9, 10, 1, 2, eye)
        fill(14, 10, 1, 2, eye)
        fill(12, 12, 1, 1, skinShadow)
        fill(11, 14, 2, 1, palette.mouth)
        if generator.nextBool() {
            fill(8, 13, 1, 1, palette.cheek)
            fill(15, 13, 1, 1, palette.cheek)
        }

        drawAccessory(
            accessory,
            palette: palette,
            hair: hair,
            fill: fill
        )

        guard let image = context.makeImage() else {
            return NSImage(size: NSSize(width: dimension, height: dimension))
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: dimension, height: dimension)
        )
    }

    private func drawBackground(
        pattern: Int,
        palette: PixelPalette,
        fill: (Int, Int, Int, Int, CGColor) -> Void
    ) {
        switch pattern {
        case 0:
            fill(15, 2, 5, 1, palette.backgroundAccent)
            fill(13, 3, 9, 4, palette.backgroundAccent)
            fill(15, 7, 5, 1, palette.backgroundAccent)
        case 1:
            for offset in stride(from: -8, through: 24, by: 6) {
                for step in 0..<5 {
                    let x = offset + step
                    if (0..<24).contains(x) {
                        fill(x, step, 1, 1, palette.backgroundAccent)
                        fill(x, step + 12, 1, 1, palette.backgroundAccent)
                    }
                }
            }
        case 2:
            fill(0, 15, 24, 9, palette.backgroundAccent)
            fill(0, 14, 8, 1, palette.backgroundAccent)
            fill(16, 14, 8, 1, palette.backgroundAccent)
        default:
            for point in [(3, 4), (19, 4), (2, 12), (21, 13), (4, 19), (19, 20)] {
                fill(point.0, point.1, 2, 2, palette.backgroundAccent)
            }
        }
    }

    private func drawHair(
        style: Int,
        color: CGColor,
        fill: (Int, Int, Int, Int, CGColor) -> Void
    ) {
        switch style {
        case 0:
            fill(7, 4, 10, 4, color)
            fill(8, 3, 8, 1, color)
            fill(7, 8, 3, 2, color)
            fill(14, 8, 3, 1, color)
        case 1:
            fill(7, 4, 10, 3, color)
            fill(7, 7, 8, 1, color)
            fill(7, 8, 5, 1, color)
            fill(7, 9, 2, 4, color)
        case 2:
            fill(6, 3, 12, 5, color)
            fill(5, 5, 2, 6, color)
            fill(17, 5, 2, 6, color)
            fill(8, 2, 3, 2, color)
            fill(13, 2, 3, 2, color)
        case 3:
            fill(7, 4, 10, 4, color)
            fill(6, 7, 2, 8, color)
            fill(16, 7, 2, 8, color)
            fill(8, 3, 8, 1, color)
        default:
            fill(7, 5, 10, 3, color)
            fill(8, 4, 2, 1, color)
            fill(11, 3, 2, 2, color)
            fill(14, 4, 2, 1, color)
            fill(7, 8, 3, 1, color)
        }
    }

    private func drawAccessory(
        _ accessory: Int,
        palette: PixelPalette,
        hair: CGColor,
        fill: (Int, Int, Int, Int, CGColor) -> Void
    ) {
        switch accessory {
        case 0:
            fill(8, 10, 3, 1, palette.accessory)
            fill(8, 11, 1, 2, palette.accessory)
            fill(10, 11, 1, 2, palette.accessory)
            fill(11, 11, 2, 1, palette.accessory)
            fill(13, 10, 3, 1, palette.accessory)
            fill(13, 11, 1, 2, palette.accessory)
            fill(15, 11, 1, 2, palette.accessory)
        case 1:
            fill(16, 8, 1, 4, palette.clothingAccent)
            fill(17, 10, 1, 3, palette.accessory)
        case 2:
            fill(7, 6, 2, 1, palette.accessory)
            fill(8, 5, 1, 1, palette.accessory)
        case 3:
            fill(6, 8, 1, 5, palette.accessory)
            fill(17, 8, 1, 5, palette.accessory)
            fill(7, 6, 1, 2, hair)
            fill(16, 6, 1, 2, hair)
        default:
            break
        }
    }

    private func palette(for style: SolPixelAvatarStyle) -> PixelPalette {
        switch style {
        case .solar:
            PixelPalette("F2B84B", "DC6843", "263D63", "6EC6B8", "753A34", "E88C7B", "F8E5A2")
        case .aurora:
            PixelPalette("264B54", "4EAD94", "7356A2", "A8DBB8", "613745", "D78496", "EAF4D3")
        case .ocean:
            PixelPalette("255C75", "67B7C7", "172F4D", "E0B45C", "623A42", "D88983", "D9F4F0")
        case .ember:
            PixelPalette("7A302C", "D9693B", "342B3E", "F0A45D", "6B3030", "E88470", "FFE0A6")
        case .violet:
            PixelPalette("503B73", "A06CC0", "282B52", "E5A7D3", "65344F", "E78DA6", "F3D8FF")
        case .graphite:
            PixelPalette("34383F", "666D78", "20242A", "AAB2BF", "5B3439", "B96F79", "E6E9EF")
        }
    }

    private var skinTones: [CGColor] {
        ["F6D4B8", "E9B68F", "CB865D", "995B3C", "633B2A"].map(Self.color)
    }

    private var skinShadows: [CGColor] {
        ["DDAA88", "CF8F68", "AD6748", "74402F", "442A24"].map(Self.color)
    }

    private var hairColors: [CGColor] {
        ["2A2020", "51362C", "8D5B3D", "D0A75B", "B6503E", "2F425C"].map(Self.color)
    }

    private var eyeColors: [CGColor] {
        ["241F26", "394A42", "36536B", "664634"].map(Self.color)
    }

    private func styleSalt(_ style: SolPixelAvatarStyle) -> UInt64 {
        style.rawValue.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
    }

    nonisolated fileprivate static func color(_ hex: String) -> CGColor {
        let value = UInt64(hex, radix: 16) ?? 0
        return CGColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

private struct PixelPalette {
    let background: CGColor
    let backgroundAccent: CGColor
    let clothing: CGColor
    let clothingAccent: CGColor
    let mouth: CGColor
    let cheek: CGColor
    let accessory: CGColor

    init(
        _ background: String,
        _ backgroundAccent: String,
        _ clothing: String,
        _ clothingAccent: String,
        _ mouth: String,
        _ cheek: String,
        _ accessory: String
    ) {
        self.background = SolPixelAvatarRenderer.color(background)
        self.backgroundAccent = SolPixelAvatarRenderer.color(backgroundAccent)
        self.clothing = SolPixelAvatarRenderer.color(clothing)
        self.clothingAccent = SolPixelAvatarRenderer.color(clothingAccent)
        self.mouth = SolPixelAvatarRenderer.color(mouth)
        self.cheek = SolPixelAvatarRenderer.color(cheek)
        self.accessory = SolPixelAvatarRenderer.color(accessory)
    }
}

private struct PixelGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextIndex(_ upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    mutating func nextBool() -> Bool {
        next() & 1 == 0
    }
}
