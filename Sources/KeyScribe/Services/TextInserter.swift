import AppKit
import Carbon

enum TextInserter {
    enum Result: String {
        case pasted = "pasted"
        case copiedOnly = "copied-only"
        case notInserted = "not-inserted"
        case empty = "empty"
    }

    @MainActor
    static func insert(_ text: String, copyToClipboard: Bool) -> Result {
        if text.isEmpty {
            let decision = InsertionDecisionModel.evaluate(
                text: text,
                copyToClipboard: copyToClipboard,
                directInsertSucceeded: false,
                typingInsertSucceeded: false,
                specialPasteSucceeded: false
            )
            return complete(with: decision, text: text, copyToClipboard: copyToClipboard)
        }

        if insertDirectlyIntoFocusedTextInput(text) {
            if copyToClipboard {
                copyTextToPasteboard(text)
            }

            let decision = InsertionDecisionModel.evaluate(
                text: text,
                copyToClipboard: copyToClipboard,
                directInsertSucceeded: true,
                typingInsertSucceeded: false,
                specialPasteSucceeded: false
            )
            return complete(with: decision, text: text, copyToClipboard: copyToClipboard)
        }

        if insertByTyping(text) {
            if copyToClipboard {
                copyTextToPasteboard(text)
            }

            let decision = InsertionDecisionModel.evaluate(
                text: text,
                copyToClipboard: copyToClipboard,
                directInsertSucceeded: false,
                typingInsertSucceeded: true,
                specialPasteSucceeded: false
            )
            return complete(with: decision, text: text, copyToClipboard: copyToClipboard)
        }

        if copyToClipboard {
            copyTextToPasteboard(text)
            let pasted = sendSpecialPasteShortcut()
            let decision = InsertionDecisionModel.evaluate(
                text: text,
                copyToClipboard: copyToClipboard,
                directInsertSucceeded: false,
                typingInsertSucceeded: false,
                specialPasteSucceeded: pasted
            )
            return complete(with: decision, text: text, copyToClipboard: copyToClipboard)
        }

        // Clipboard writes are disabled, but we still need a robust paste fallback.
        // Temporarily use the clipboard for the special paste shortcut, then restore previous clipboard content.
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.compactMap { $0.copy() as? NSPasteboardItem } ?? []

        copyTextToPasteboard(text)
        let temporaryWriteChangeCount = pasteboard.changeCount
        let pasted = sendSpecialPasteShortcut()
        restorePasteboardItems(previousItems, expectedChangeCount: temporaryWriteChangeCount)

        let decision = InsertionDecisionModel.evaluate(
            text: text,
            copyToClipboard: copyToClipboard,
            directInsertSucceeded: false,
            typingInsertSucceeded: false,
            specialPasteSucceeded: pasted
        )
        return complete(with: decision, text: text, copyToClipboard: copyToClipboard)
    }

    @MainActor
    private static func complete(with decision: InsertionDecision, text: String, copyToClipboard: Bool) -> Result {
        InsertionDiagnostics.record(decision: decision, text: text, copyToClipboard: copyToClipboard)
        return decision.result
    }

    @MainActor
    private static func copyTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    private static func restorePasteboardItems(_ items: [NSPasteboardItem], expectedChangeCount: Int) {
        let pasteboard = NSPasteboard.general
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard pasteboard.changeCount == expectedChangeCount else {
                return
            }

            pasteboard.clearContents()
            if !items.isEmpty {
                pasteboard.writeObjects(items)
            }
        }
    }

    private static func sendSpecialPasteShortcut() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState) ?? CGEventSource(stateID: .hidSystemState)
        guard let source else {
            return false
        }

        let commandKeyCode: CGKeyCode = 55 // Left Command
        let optionKeyCode: CGKeyCode = 58 // Left Option
        let vKeyV: CGKeyCode = 9 // kVK_ANSI_V

        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
            let optionDown = CGEvent(keyboardEventSource: source, virtualKey: optionKeyCode, keyDown: true),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: false),
            let optionUp = CGEvent(keyboardEventSource: source, virtualKey: optionKeyCode, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        else {
            return false
        }

        commandDown.post(tap: .cgSessionEventTap)
        optionDown.post(tap: .cgSessionEventTap)

        keyDown.flags = [.maskCommand, .maskAlternate]
        keyDown.post(tap: .cgSessionEventTap)

        keyUp.flags = [.maskCommand, .maskAlternate]
        keyUp.post(tap: .cgSessionEventTap)

        optionUp.post(tap: .cgSessionEventTap)
        commandUp.post(tap: .cgSessionEventTap)

        return true
    }

    // Non-clipboard fallback: types text directly into the focused field.
    private static func insertByTyping(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState) ?? CGEventSource(stateID: .hidSystemState)
        guard let source else {
            return false
        }

        for scalar in text.unicodeScalars {
            if scalar.value == 10 {
                guard
                    let returnDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                    let returnUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
                else {
                    return false
                }
                returnDown.post(tap: .cgSessionEventTap)
                returnUp.post(tap: .cgSessionEventTap)
                continue
            }

            var utf16Units = Array(String(scalar).utf16)
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return false
            }

            keyDown.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
            keyUp.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)

            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }

        return true
    }

    // Tries to insert/replace text in the currently focused element via Accessibility.
    private static func insertDirectlyIntoFocusedTextInput(_ text: String) -> Bool {
        guard let focusedElement = focusedTextElement() else {
            return false
        }

        // Preferred path for rich text/native editors: replace currently selected text.
        if AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success {
            return true
        }

        var currentValueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &currentValueRef
        )
        guard valueResult == .success, let currentValue = currentValueRef as? String else {
            return false
        }

        var selectedRangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )
        guard rangeResult == .success, let selectedRangeRef else {
            return false
        }

        guard CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return false
        }

        let selectedRangeAX = unsafeBitCast(selectedRangeRef, to: AXValue.self)
        guard AXValueGetType(selectedRangeAX) == .cfRange else {
            return false
        }

        var selectedRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(selectedRangeAX, .cfRange, &selectedRange) else {
            return false
        }

        let currentNSString = currentValue as NSString
        let safeLocation = max(0, min(selectedRange.location, currentNSString.length))
        let safeLength = max(0, min(selectedRange.length, currentNSString.length - safeLocation))
        let replacementRange = NSRange(location: safeLocation, length: safeLength)
        let updatedValue = currentNSString.replacingCharacters(in: replacementRange, with: text)

        let setValueResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setValueResult == .success else {
            return false
        }

        var newSelection = CFRange(location: safeLocation + (text as NSString).length, length: 0)
        if let newSelectionAX = AXValueCreate(.cfRange, &newSelection) {
            _ = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                newSelectionAX
            )
        }

        return true
    }

    private static func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedResult == .success, let focusedRef else {
            return nil
        }

        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }
}
