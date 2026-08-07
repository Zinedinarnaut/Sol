import SwiftUI

struct DirectoryPickerView: View {
    let title: String
    @Binding var path: String
    let validation: ValidationResult
    let allowsFiles: Bool
    let onPickURL: ((URL) -> Void)?
    @State private var isPanelPresented = false
    @State private var activePanel: NSOpenPanel?
    @State private var hostingWindow: NSWindow?

    init(title: String, path: Binding<String>, validation: ValidationResult, allowsFiles: Bool = false, onPickURL: ((URL) -> Void)? = nil) {
        self.title = title
        self._path = path
        self.validation = validation
        self.allowsFiles = allowsFiles
        self.onPickURL = onPickURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    Text(path.isEmpty ? "Not selected" : path)
                        .foregroundStyle(path.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(path)

                    Button("Choose…") {
                        openPanel()
                    }
                }
            }

            Label(
                validation.message,
                systemImage: validation.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(validation.isValid ? Color.secondary : Color.red)
        }
        .background(WindowAccessor(window: $hostingWindow))
    }

    @MainActor
    private func openPanel() {
        guard !isPanelPresented else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = allowsFiles
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.prompt = "Choose"
        panel.treatsFilePackagesAsDirectories = false
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }

        isPanelPresented = true
        activePanel = panel

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            defer {
                isPanelPresented = false
                activePanel = nil
            }
            guard response == .OK, let url = panel.url else { return }
            // Persist the grant before publishing the path. Settings observers
            // validate and scan immediately when `path` changes.
            onPickURL?(url)
            path = url.path
        }

        let targetWindow = hostingWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let window = targetWindow, window.sheetParent == nil {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            let response = panel.runModal()
            handleResponse(response)
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            self.window = view?.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            self.window = nsView?.window
        }
    }
}
