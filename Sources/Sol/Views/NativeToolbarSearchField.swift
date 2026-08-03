import AppKit
import SwiftUI

struct NativeToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> CenteredToolbarSearchField {
        let searchField = CenteredToolbarSearchField()
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.searchChanged(_:))
        searchField.placeholderString = placeholder
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.setAccessibilityLabel("Search game library")
        return searchField
    }

    func updateNSView(_ searchField: CenteredToolbarSearchField, context: Context) {
        if searchField.stringValue != text {
            searchField.stringValue = text
        }

        if searchField.placeholderString != placeholder {
            searchField.placeholderString = placeholder
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: CenteredToolbarSearchField,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: min(max(proposal.width ?? 440, 320), 520),
            height: nsView.intrinsicContentSize.height
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            updateText(from: sender)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }

            updateText(from: searchField)
        }

        private func updateText(from searchField: NSSearchField) {
            guard text != searchField.stringValue else {
                return
            }

            text = searchField.stringValue
        }
    }
}

@MainActor
final class CenteredToolbarSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.centerToolbarItem()
        }
    }

    private func centerToolbarItem() {
        guard let toolbar = window?.toolbar,
              let toolbarItem = toolbar.items.first(where: { item in
                  guard let itemView = item.view else {
                      return false
                  }

                  return self === itemView || isDescendant(of: itemView)
              }) else {
            return
        }

        toolbar.centeredItemIdentifiers = [toolbarItem.itemIdentifier]
    }
}
