import SwiftUI

struct WidgetGameCard: View {
    let image: Image?
    let size: CGSize
    let emphasis: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(WidgetTheme.panel.opacity(0.9))

            if let image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Text("No Art")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(WidgetTheme.textMuted)
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.05),
                    Color.black.opacity(0.25)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .opacity(emphasis)
        .clipped()
    }

    static func posterSize(height: CGFloat) -> CGSize {
        CGSize(width: height * 0.66, height: height)
    }
}
