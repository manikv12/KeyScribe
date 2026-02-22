import AppKit
import Carbon
import OSLog

enum TextInserter {
    enum Result: String, Equatable {
        case pasted = "pasted"
        case copiedOnly = "copied-only"
        case notInserted = "not-inserted"
        case empty = "empty"
    }

    struct InsertOutcome: Equatable {
        let result: Result
        let debugStatus: String?
    }

    enum ClipboardWriteOutcome: Equatable {
        case success(changeCount: Int)
        case failure(debugStatus: String)
    }

    struct ClipboardSnapshot {
        fileprivate let items: [NSPasteboardItem]

        init(items: [NSPasteboardItem] = []) {
            self.items = items
        }
    }

    struct Runtime {
        var insertDirect: (String) -> Bool
        var insertTyping: (String) -> Bool
        var writeClipboard: (String) -> ClipboardWriteOutcome
        var sendSpecialPaste: () -> Bool
        var captureClipboard: () -> ClipboardSnapshot
        var restoreClipboard: (ClipboardSnapshot, Int) -> Void
        var log: (String) -> Void
        var pasteRetryBackoff: [TimeInterval]

        init(
            insertDirect: @escaping (String) -> Bool,
            insertTyping: @escaping (String) -> Bool,
            writeClipboard: @escaping (String) -> ClipboardWriteOutcome,
            sendSpecialPaste: @escaping () -> Bool,
            captureClipboard: @escaping () -> ClipboardSnapshot = { ClipboardSnapshot() },
            restoreClipboard: @escaping (ClipboardSnapshot, Int) -> Void = { _, _ in },
            log: @escaping (String) -> Void = { _ in },
            pasteRetryBackoff: [TimeInterval] = [0, 0.04, 0.1]
        ) {
            self.insertDirect = insertDirect
            self.insertTyping = insertTyping
            self.writeClipboard = writeClipboard
            self.sendSpecialPaste = sendSpecialPaste
            self.captureClipboard = captureClipboard
            self.restoreClipboard = restoreClipboard
            self.log = log
            self.pasteRetryBackoff = pasteRetryBackoff
        }
    }

    @MainActor
    private(set) static var lastDebugStatus: String?

    private static let logger = Logger(subsystem: "KeyScribe", category: "TextInserter")
    private static let clipboardWriteRetryBackoff: [TimeInterval] = [0, 0.015, 0.05]
    private static let clipboardRestoreDelay: TimeInterval = 0.24

    @MainActor
    static func insert(_ text: String, copyToClipboard: Bool) -> Result {
        let outcome = performInsert(text, copyToClipboard: copyToClipboard, runtime: makeLiveRuntime())
        lastDebugStatus = outcome.debugStatus

        if let debugStatus = outcome.debugStatus, outcome.result != .pasted {
            logger.debug("Insertion finished as \(resultLabel(outcome.result), privacy: .public) [\(debugStatus, privacy: .public)]")
        }

        return outcome.result
    }

    // Test-only insertion entrypoint used by smoke tests to validate clipboard flow deterministically.
    static func insertForSmokeTests(_ text: String, copyToClipboard: Bool, runtime: Runtime) -> InsertOutcome {
        performInsert(text, copyToClipboard: copyToClipboard, runtime: runtime)
    }

    private static func performInsert(_ text: String, copyToClipboard: Bool, runtime: Runtime) -> InsertOutcome {
        guard !text.isEmpty else { return InsertOutcome(result: .empty, debugStatus: nil) }

        if runtime.insertDirect(text) {
            if copyToClipboard {
                if case let .failure(debugStatus) = runtime.writeClipboard(text) {
                    runtime.log("Direct insert succeeded but clipboard copy failed [\(debugStatus)]")
                }
            }
            return InsertOutcome(result: .pasted, debugStatus: nil)
        }

        if copyToClipboard {
            return insertWithClipboardPreferred(text, runtime: runtime)
        }

        if runtime.insertTyping(text) {
            return InsertOutcome(result: .pasted, debugStatus: nil)
        }

        return insertWithTemporaryClipboardFallback(text, runtime: runtime)
    }

    private static func insertWithClipboardPreferred(_ text: String, runtime: Runtime) -> InsertOutcome {
        switch runtime.writeClipboard(text) {
        case let .failure(debugStatus):
            runtime.log("Clipboard write verification failed before paste [\(debugStatus)]")
            if runtime.insertTyping(text) {
                return InsertOutcome(result: .pasted, debugStatus: nil)
            }
            return InsertOutcome(result: .notInserted, debugStatus: debugStatus)

        case .success:
            if triggerPasteShortcutWithRetry(runtime: runtime) {
                return InsertOutcome(result: .pasted, debugStatus: nil)
            }

            runtime.log("Special paste shortcut failed; attempting typing fallback")
            if runtime.insertTyping(text) {
                return InsertOutcome(result: .pasted, debugStatus: nil)
            }

            return InsertOutcome(result: .copiedOnly, debugStatus: "paste-shortcut-unavailable")
        }
    }

    private static func insertWithTemporaryClipboardFallback(_ text: String, runtime: Runtime) -> InsertOutcome {
        let snapshot = runtime.captureClipboard()

        switch runtime.writeClipboard(text) {
        case let .failure(debugStatus):
            runtime.log("Temporary clipboard write verification failed [\(debugStatus)]")
            return InsertOutcome(result: .notInserted, debugStatus: debugStatus)

        case let .success(changeCount):
            if triggerPasteShortcutWithRetry(runtime: runtime) {
                runtime.restoreClipboard(snapshot, changeCount)
                return InsertOutcome(result: .pasted, debugStatus: nil)
            }

            // Keep transcript on clipboard when the temporary paste flow fails.
            // This gives the user a manual fallback instead of losing both insert + clipboard states.
            runtime.log("Temporary paste failed; leaving transcript on clipboard for manual paste")
            return InsertOutcome(result: .copiedOnly, debugStatus: "paste-shortcut-unavailable")
        }
    }

    private static func triggerPasteShortcutWithRetry(runtime: Runtime) -> Bool {
        for (attemptIndex, delay) in runtime.pasteRetryBackoff.enumerated() {
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }

            if runtime.sendSpecialPaste() {
                if attemptIndex > 0 {
                    runtime.log("Special paste shortcut succeeded on retry \(attemptIndex + 1)")
                }
                return true
            }
        }

        return false
    }

    @MainActor
    private static func makeLiveRuntime() -> Runtime {
        Runtime(
            insertDirect: { text in
                insertDirectlyIntoFocusedTextInput(text)
            },
            insertTyping: { text in
                insertByTyping(text)
            },
            writeClipboard: { text in
                verifiedClipboardWrite(text)
            },
            sendSpecialPaste: {
                sendSpecialPasteShortcutOnce()
            },
            captureClipboard: {
                capturePasteboardSnapshot()
            },
            restoreClipboard: { snapshot, changeCount in
                restorePasteboardSnapshot(snapshot, expectedChangeCount: changeCount)
            },
            log: { message in
                logger.debug("\(message, privacy: .public)")
            }
        )
    }

    @MainActor
    private static func verifiedClipboardWrite(_ text: String) -> ClipboardWriteOutcome {
        let pasteboard = NSPasteboard.general
        var lastFailure = "clipboard-write-rejected"

        for delay in clipboardWriteRetryBackoff {
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }

            let beforeChangeCount = pasteboard.changeCount
            pasteboard.clearContents()

            guard pasteboard.setString(text, forType: .string) else {
                lastFailure = "clipboard-write-rejected"
                continue
            }

            let afterChangeCount = pasteboard.changeCount
            guard pasteboard.string(forType: .string) == text else {
                lastFailure = "clipboard-readback-mismatch"
                continue
            }

            guard afterChangeCount != beforeChangeCount else {
                lastFailure = "clipboard-change-count-stale"
                continue
            }

            return .success(changeCount: afterChangeCount)
        }

        return .failure(debugStatus: lastFailure)
    }

    @MainActor
    private static func capturePasteboardSnapshot() -> ClipboardSnapshot {
        let items = NSPasteboard.general.pasteboardItems?.compactMap { $0.copy() as? NSPasteboardItem } ?? []
        return ClipboardSnapshot(items: items)
    }

    @MainActor
    private static func restorePasteboardSnapshot(_ snapshot: ClipboardSnapshot, expectedChangeCount: Int) {
        let pasteboard = NSPasteboard.general
        let savedItems = snapshot.items

        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            guard pasteboard.changeCount == expectedChangeCount else {
                return
            }

            pasteboard.clearContents()
            if !savedItems.isEmpty, !pasteboard.writeObjects(savedItems) {
                logger.debug("Pasteboard restore writeObjects failed")
            }
        }
    }

    private static func sendSpecialPasteShortcutOnce() -> Bool {
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

        Thread.sleep(forTimeInterval: 0.006)

        keyDown.flags = [.maskCommand, .maskAlternate]
        keyDown.post(tap: .cgSessionEventTap)

        keyUp.flags = [.maskCommand, .maskAlternate]
        keyUp.post(tap: .cgSessionEventTap)

        Thread.sleep(forTimeInterval: 0.004)

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

    private static func resultLabel(_ result: Result) -> String {
        switch result {
        case .pasted:
            return "pasted"
        case .copiedOnly:
            return "copiedOnly"
        case .notInserted:
            return "notInserted"
        case .empty:
            return "empty"
        }
    }
}
