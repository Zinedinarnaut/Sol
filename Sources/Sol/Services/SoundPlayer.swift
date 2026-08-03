import AppKit
import QuartzCore

enum UISoundEffect {
    case focus
    case select
    case launch
}

final class SoundPlayer: @unchecked Sendable {
    static let shared = SoundPlayer()

    private let sounds: [UISoundEffect: NSSound]
    private var lastPlayed: [UISoundEffect: TimeInterval] = [:]

    private init() {
        let focus = NSSound(named: NSSound.Name("Tink"))
        let select = NSSound(named: NSSound.Name("Pop"))
        let launch = NSSound(named: NSSound.Name("Submarine"))

        focus?.volume = 0.18
        select?.volume = 0.2
        launch?.volume = 0.24

        sounds = [
            .focus: focus,
            .select: select,
            .launch: launch
        ].compactMapValues { $0 }
    }

    func play(_ effect: UISoundEffect) {
        let now = CACurrentMediaTime()
        let throttle = throttleInterval(for: effect)
        if let last = lastPlayed[effect], now - last < throttle {
            return
        }
        lastPlayed[effect] = now

        DispatchQueue.main.async {
            self.sounds[effect]?.play()
        }
    }

    private func throttleInterval(for effect: UISoundEffect) -> TimeInterval {
        switch effect {
        case .focus:
            return 0.08
        case .select:
            return 0.12
        case .launch:
            return 0.3
        }
    }
}
