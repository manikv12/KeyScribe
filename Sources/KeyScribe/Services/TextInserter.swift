import AppKit

enum TextInserter {
    enum Result: String {
        case pasted = "pasted"
        case copiedOnly = "copied-only"
        case notInserted = "not-inserted"
        case empty = "empty"
    }

    enum PasteAttemptOutcome: Equatable {
        case inserted
        case notInserted
        case unverified
    }

    enum PasteFallbackDecision: Equatable {
        case skipCommandOptionV
        case tryCommandOptionV
    }

    struct VerificationState: Equatable {
        let value: String?
        let selectedText: String?
        let selectedRange: NSRange?
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
            let pasted = pasteFromClipboard(text)
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
        // Temporarily use the clipboard for paste shortcuts, then restore previous clipboard content.
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.compactMap { $0.copy() as? NSPasteboardItem } ?? []

        copyTextToPasteboard(text)
        let temporaryWriteChangeCount = pasteboard.changeCount
        let pasted = pasteFromClipboard(text)
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

    static func pasteFallbackDecision(afterPrimaryOutcome outcome: PasteAttemptOutcome) -> PasteFallbackDecision {
        switch outcome {
        case .notInserted:
            return .tryCommandOptionV
        case .inserted, .unverified:
            return .skipCommandOptionV
        }
    }

    static func didInsertText(_ text: String, before: VerificationState, after: VerificationState) -> Bool {
        if let beforeValue = before.value,
           let afterValue = after.value,
           beforeValue != afterValue {
            return true
        }

        if let beforeSelected = before.selectedText,
           let afterSelected = after.selectedText,
           beforeSelected != afterSelected,
           !text.isEmpty,
           afterSelected == text {
            return true
        }

        if let beforeRange = before.selectedRange,
           let afterRange = after.selectedRange {
            let replacementLength = (text as NSString).length
            let expectedCaret = beforeRange.location + max(0, replacementLength - beforeRange.length)
            if afterRange.length == 0,
               afterRange.location == expectedCaret,
               (beforeRange.length > 0 || replacementLength > 0) {
                return true
            }
        }

        return false
    }

    private static func hasComparableObservation(before: VerificationState, after: VerificationState) -> Bool {
        (before.value != nil && after.value != nil)
            || (before.selectedText != nil && after.selectedText != nil)
            || (before.selectedRange != nil && after.selectedRange != nil)
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

    @MainActor
    private static func pasteFromClipboard(_ text: String) -> Bool {
        let baseline = focusedElementSnapshot()

        guard sendPasteShortcut(.commandV) else {
            return false
        }

        let primaryOutcome = verifyInsertionOutcome(expectedText: text, baseline: baseline)
        switch primaryOutcome {
        case .inserted, .unverified:
            return true
        case .notInserted:
            break
        }

        guard pasteFallbackDecision(afterPrimaryOutcome: primaryOutcome) == .tryCommandOptionV else {
            return false
        }

        guard sendPasteShortcut(.commandOptionV) else {
            return false
        }

        let specialOutcome = verifyInsertionOutcome(expectedText: text, baseline: baseline)
        return specialOutcome != .notInserted
    }

    private enum PasteShortcut {
        case commandV
        case commandOptionV
    }

    private static func sendPasteShortcut(_ shortcut: PasteShortcut) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState) ?? CGEventSource(stateID: .hidSystemState)
        guard let source else {
            return false
        }

        let commandKeyCode: CGKeyCode = 55 // Left Command
        let optionKeyCode: CGKeyCode = 58 // Left Option
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        else {
            return false
        }

        switch shortcut {
        case .commandV:
            commandDown.post(tap: .cgSessionEventTap)

            keyDown.flags = [.maskCommand]
            keyDown.post(tap: .cgSessionEventTap)

            keyUp.flags = [.maskCommand]
            keyUp.post(tap: .cgSessionEventTap)

            commandUp.post(tap: .cgSessionEventTap)
            return true
        case .commandOptionV:
            guard
                let optionDown = CGEvent(keyboardEventSource: source, virtualKey: optionKeyCode, keyDown: true),
                let optionUp = CGEvent(keyboardEventSource: source, virtualKey: optionKeyCode, keyDown: false)
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
    }

    // Non-clipboard fallback: types text directly into the focused field.
    @MainActor
    private static func insertByTyping(_ text: String) -> Bool {
        let baseline = focusedElementSnapshot()

        let source = CGEventSource(stateID: .combinedSessionState) ?? CGEventSource(stateID: .hidSystemState)
        guard let source else {
            return false
        }

        for scalar in text.unicodeScalars {
            if scalar.value == 10 || scalar.value == 13 {
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

        let outcome = verifyInsertionOutcome(expectedText: text, baseline: baseline)
        return outcome != .notInserted
    }

    // Tries to insert/replace text in the currently focused element via Accessibility.
    @MainActor
    private static func insertDirectlyIntoFocusedTextInput(_ text: String) -> Bool {
        guard let baseline = focusedElementSnapshot() else {
            return false
        }

        let focusedElement = baseline.element

        // Preferred path for rich text/native editors: replace currently selected text.
        if AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success {
            if verifyInsertionOutcome(expectedText: text, baseline: baseline) == .inserted {
                return true
            }
        }

        guard let currentValue = stringAttribute(kAXValueAttribute as CFString, from: focusedElement),
              let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: focusedElement)
        else {
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

        if stringAttribute(kAXValueAttribute as CFString, from: focusedElement) == updatedValue {
            return true
        }

        return verifyInsertionOutcome(expectedText: text, baseline: baseline) == .inserted
    }

    private struct FocusedElementSnapshot {
        let element: AXUIElement
        let state: VerificationState
    }

    @MainActor
    private static func verifyInsertionOutcome(expectedText: String, baseline: FocusedElementSnapshot?) -> PasteAttemptOutcome {
        let pollCount = 4
        var outcome: PasteAttemptOutcome = .unverified

        for index in 0..<pollCount {
            outcome = evaluateInsertionOutcome(expectedText: expectedText, baseline: baseline)
            if outcome == .inserted {
                return .inserted
            }

            if index < pollCount - 1 {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
        }

        return outcome
    }

    @MainActor
    private static func evaluateInsertionOutcome(expectedText: String, baseline: FocusedElementSnapshot?) -> PasteAttemptOutcome {
        guard let baseline else {
            return .unverified
        }

        guard let after = focusedElementSnapshot() else {
            return .unverified
        }

        guard CFEqual(baseline.element, after.element) else {
            return .unverified
        }

        guard hasComparableObservation(before: baseline.state, after: after.state) else {
            return .unverified
        }

        if didInsertText(expectedText, before: baseline.state, after: after.state) {
            return .inserted
        }

        return .notInserted
    }

    @MainActor
    private static func focusedElementSnapshot() -> FocusedElementSnapshot? {
        guard let element = focusedTextElement() else {
            return nil
        }

        let state = VerificationState(
            value: stringAttribute(kAXValueAttribute as CFString, from: element),
            selectedText: stringAttribute(kAXSelectedTextAttribute as CFString, from: element),
            selectedRange: rangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element)
        )

        return FocusedElementSnapshot(element: element, state: state)
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }

        return valueRef as? String
    }

    private static func rangeAttribute(_ attribute: CFString, from element: AXUIElement) -> NSRange? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success, let valueRef else {
            return nil
        }

        guard CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return NSRange(location: range.location, length: range.length)
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
