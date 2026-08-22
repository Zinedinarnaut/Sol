import SwiftUI

struct EmulationControlBar: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        HStack(spacing: 12) {
            sessionIdentity

            Divider()
                .frame(height: 24)

            Button(action: viewModel.toggleEmulationPause) {
                Label(
                    viewModel.session.isPaused ? "Resume" : "Pause",
                    systemImage: viewModel.session.isPaused ? "play.fill" : "pause.fill"
                )
                .labelStyle(.iconOnly)
            }
            .help(viewModel.session.isPaused ? "Resume Emulation" : "Pause Emulation")

            Button(action: viewModel.toggleEmulationFullscreen) {
                Label(
                    viewModel.session.isFullscreen ? "Exit Full Screen" : "Enter Full Screen",
                    systemImage: viewModel.session.isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .labelStyle(.iconOnly)
            }
            .help(viewModel.session.isFullscreen ? "Exit Full Screen" : "Enter Full Screen")

            Button(action: viewModel.takeScreenshot) {
                Label("Take Screenshot", systemImage: "camera")
                    .labelStyle(.iconOnly)
            }
            .help("Take Screenshot")

            Button(action: viewModel.showAmiiboPicker) {
                Label("Scan NFC Figure", systemImage: "wave.3.right.circle")
                    .labelStyle(.iconOnly)
            }
            .disabled(!viewModel.canScanAmiibo)
            .help("Scan NFC Figure")

            HStack(spacing: 7) {
                Image(systemName: volumeSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Slider(
                    value: Binding(
                        get: { Double(viewModel.session.volume) },
                        set: { viewModel.setEmulationVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .frame(width: 112)
                .help("Emulation Volume")
            }

            Button(role: .destructive, action: viewModel.stopLaunch) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
            }
            .help("Stop Emulation")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Emulation controls")
    }

    private var sessionIdentity: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(viewModel.session.title ?? viewModel.selectedGame?.title ?? "Sol")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(phaseTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 116, maxWidth: 220, alignment: .leading)
    }

    private var phaseTitle: String {
        switch viewModel.session.phase {
        case .idle:
            return "Starting engine…"
        case .launching:
            return "Loading…"
        case .running:
            return "Running"
        case .paused:
            return "Paused"
        case .stopping:
            return "Stopping…"
        }
    }

    private var volumeSymbol: String {
        switch viewModel.session.volume {
        case ...0:
            return "speaker.slash.fill"
        case ..<0.4:
            return "speaker.wave.1.fill"
        case ..<0.75:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }
}
