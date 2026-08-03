import SwiftUI

struct ConsoleView: View {
    let lines: [ConsoleLine]
    let onClear: () -> Void

    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Sol Console", systemImage: "terminal")
                    .font(.headline)

                Spacer()

                Toggle("Follow Output", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Button(role: .destructive, action: onClear) {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(lines.isEmpty)
            }

            GroupBox {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if lines.isEmpty {
                                ContentUnavailableView(
                                    "No Console Output",
                                    systemImage: "terminal",
                                    description: Text("Sol and Sol Engine messages will appear here.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 360)
                            } else {
                                ForEach(lines) { line in
                                    Text(line.text)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(color(for: line.stream))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("console-bottom")
                        }
                        .padding(10)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: lines.count) { _, _ in
                        guard autoScroll else { return }
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding(12)
    }

    private func color(for stream: ConsoleStream) -> Color {
        switch stream {
        case .stdout:
            return .primary
        case .stderr:
            return .red
        case .system:
            return .secondary
        }
    }
}
