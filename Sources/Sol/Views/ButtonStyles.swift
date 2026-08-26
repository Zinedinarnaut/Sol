import SwiftUI

/// Shared geometry for Sol's native surfaces. The values intentionally sit
/// between sharp utility panels and the oversized pills that make dense macOS
/// interfaces feel toy-like.
enum SolGeometry {
    static let controlCornerRadius: CGFloat = 8
    static let cardCornerRadius: CGFloat = 12
    static let panelCornerRadius: CGFloat = 14
    static let windowCornerRadius: CGFloat = 16
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next", size: 13).weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? Theme.panelAlt : Theme.panelElevated)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: SolGeometry.controlCornerRadius,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: SolGeometry.controlCornerRadius,
                    style: .continuous
                )
                    .stroke(Theme.borderStrong.opacity(configuration.isPressed ? 0.6 : 0.9), lineWidth: 1)
            )
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next", size: 12).weight(.medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(configuration.isPressed ? Theme.panel : Color.clear)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: SolGeometry.controlCornerRadius,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: SolGeometry.controlCornerRadius,
                    style: .continuous
                )
                    .stroke(Theme.border.opacity(0.8), lineWidth: 1)
            )
    }
}

/// Opens Sol's single native Settings window while preserving the caller's
/// label and button styling.
struct SolSettingsLink<Label: View>: View {
    @Environment(\.openWindow) private var openWindow
    private let label: Label

    init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    var body: some View {
        Button {
            openWindow(id: "settings")
        } label: {
            label
        }
    }
}
