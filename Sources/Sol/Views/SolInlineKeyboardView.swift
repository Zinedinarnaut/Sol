import AppKit
import SwiftUI

struct SolInlineKeyboardView: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        if let keyboard = viewModel.inlineKeyboard {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                NativeInlineTextField(
                    text: keyboard.text,
                    cursorBegin: keyboard.cursorBegin,
                    cursorEnd: keyboard.cursorEnd,
                    maximumLength: keyboard.maximumLength,
                    onChange: { text, cursorBegin, cursorEnd in
                        viewModel.updateInlineKeyboard(
                            text: text,
                            cursorBegin: cursorBegin,
                            cursorEnd: cursorEnd
                        )
                    },
                    onSubmit: viewModel.submitInlineKeyboard,
                    onCancel: viewModel.cancelInlineKeyboard
                )
                .frame(minWidth: 300, idealWidth: 440, maxWidth: 560, minHeight: 30)

                Text("\(keyboard.text.utf16.count)/\(keyboard.maximumLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("Cancel", action: viewModel.cancelInlineKeyboard)
                    .keyboardShortcut(.cancelAction)

                Button("Done", action: viewModel.submitInlineKeyboard)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Game keyboard")
        }
    }
}

private struct NativeInlineTextField: NSViewRepresentable {
    let text: String
    let cursorBegin: Int
    let cursorEnd: Int
    let maximumLength: Int
    let onChange: (String, Int, Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.placeholderString = "Enter text"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.focusRingType = .default
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1

        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            context.coordinator.applySelection(to: field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.applySelection(to: field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeInlineTextField

        init(parent: NativeInlineTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            var text = field.stringValue
            if text.utf16.count > parent.maximumLength {
                text = String(text.prefix(parent.maximumLength))
                field.stringValue = text
                NSSound.beep()
            }

            let selection = (field.currentEditor() as? NSTextView)?.selectedRange()
                ?? NSRange(location: text.utf16.count, length: 0)
            parent.onChange(
                text,
                min(selection.location, text.utf16.count),
                min(selection.location + selection.length, text.utf16.count)
            )
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        func applySelection(to field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            let count = field.stringValue.utf16.count
            let start = min(max(parent.cursorBegin, 0), count)
            let end = min(max(parent.cursorEnd, start), count)
            let selection = NSRange(location: start, length: end - start)
            if editor.selectedRange() != selection {
                editor.setSelectedRange(selection)
            }
        }
    }
}
