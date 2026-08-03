import SwiftUI

enum Theme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.055, green: 0.075, blue: 0.105),
            Color(red: 0.025, green: 0.035, blue: 0.055),
            Color(red: 0.015, green: 0.018, blue: 0.028),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let panel = Color(white: 0.10)
    static let panelAlt = Color(white: 0.06)
    static let panelElevated = Color(white: 0.14)
    static let border = Color(white: 0.22)
    static let borderStrong = Color(white: 0.55)
    static let focus = Color(white: 0.9)
    static let glow = Color(white: 0.75)
    static let textPrimary = Color(white: 0.95)
    static let textSecondary = Color(white: 0.72)
    static let textMuted = Color(white: 0.5)

    static let heroGradient = LinearGradient(
        colors: [Color.black.opacity(0.85), Color.black.opacity(0.3), Color.black.opacity(0.05)],
        startPoint: .bottom,
        endPoint: .top
    )
}
