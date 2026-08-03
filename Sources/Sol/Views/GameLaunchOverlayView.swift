import AppKit
import SwiftUI

struct GameLaunchOverlayView: View {
    @ObservedObject var viewModel: LauncherViewModel
    let backgroundImage: NSImage?

    var body: some View {
        ZStack {
            launchBackdrop

            VStack(spacing: 18) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 31, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)

                VStack(spacing: 5) {
                    Text(viewModel.selectedGame?.title ?? "Starting Game")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)

                    Text("Sol Engine is preparing the game")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(
                        Array(viewModel.launchActivity.completedMessages.enumerated()),
                        id: \.offset
                    ) { _, message in
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)

                        Text(viewModel.launchActivity.message)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        if let detail = viewModel.launchActivity.progressDetail {
                            Text(detail)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let fraction = viewModel.launchActivity.progressFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Stop Launch", role: .cancel, action: viewModel.stopLaunch)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(26)
            .frame(width: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Launching \(viewModel.selectedGame?.title ?? "game")")
        .accessibilityValue(viewModel.launchActivity.message)
    }

    @ViewBuilder
    private var launchBackdrop: some View {
        if let backgroundImage {
            Image(nsImage: backgroundImage)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .blur(radius: 8)
                .scaleEffect(1.04)
                .overlay(Color.black.opacity(0.58))
        } else {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.08, green: 0.12, blue: 0.16),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
