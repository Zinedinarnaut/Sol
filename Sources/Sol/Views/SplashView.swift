import SwiftUI

struct SplashView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 40, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 88, height: 88)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .accessibilityHidden(true)

                VStack(spacing: 5) {
                    Text("Sol")
                        .font(.title2.weight(.semibold))

                    Text("Preparing your library")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Preparing your library")
            }
            .padding(32)
            .scaleEffect(animate ? 1.0 : 0.97)
            .opacity(animate ? 1.0 : 0.0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                animate = true
            }
        }
    }
}
