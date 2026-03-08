import AppKit
import Foundation

@MainActor
final class AssistantComposerBridge {
    static let shared = AssistantComposerBridge()

    private weak var textView: NSTextView?

    private init() {}

    func register(textView: NSTextView) {
        self.textView = textView
    }

    var canInsertIntoActiveComposer: Bool {
        guard let textView,
              let window = textView.window else {
            return false
        }

        return NSApp.isActive && window.isVisible && window.isKeyWindow
    }

    @discardableResult
    func insert(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let textView,
              let window = textView.window,
              canInsertIntoActiveComposer else {
            return false
        }

        if window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }

        textView.insertText(text, replacementRange: textView.selectedRange())
        return true
    }
}
