import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next", size: 13).weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? Theme.panelAlt : Theme.panelElevated)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
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
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border.opacity(0.8), lineWidth: 1)
            )
    }
}
