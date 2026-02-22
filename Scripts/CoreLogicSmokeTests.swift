import AppKit
import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("❌ \(message)\n", stderr)
        exit(1)
    }
}

@main
struct CoreLogicSmokeTests {
    static func main() {
        testShortcutValidationRules()
        testTextCleanupPipeline()
        testRecognitionTuningDeterminism()
        testInsertionRetryPolicyBounds()
        testTextInserterClipboardPaths()

        print("✅ Core logic smoke tests passed")
    }

    private static func testShortcutValidationRules() {
        let twoModifierOnly = NSEvent.ModifierFlags([.command, .option]).rawValue
        let oneModifierOnly = NSEvent.ModifierFlags([.command]).rawValue
        let fourModifierOnly = NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue

        check(ShortcutValidationRules.isValid(keyCode: UInt16.max, modifiers: twoModifierOnly), "Modifier-only shortcut should accept 2 modifiers")
        check(!ShortcutValidationRules.isValid(keyCode: UInt16.max, modifiers: oneModifierOnly), "Modifier-only shortcut should reject 1 modifier")
        check(!ShortcutValidationRules.isValid(keyCode: UInt16.max, modifiers: fourModifierOnly), "Modifier-only shortcut should reject 4 modifiers")

        let oneKeyModifier = NSEvent.ModifierFlags([.command]).rawValue
        let twoKeyModifiers = NSEvent.ModifierFlags([.command, .option]).rawValue
        let threeKeyModifiers = NSEvent.ModifierFlags([.command, .option, .shift]).rawValue

        check(ShortcutValidationRules.isValid(keyCode: 49, modifiers: oneKeyModifier), "Key shortcut should accept 1 modifier")
        check(ShortcutValidationRules.isValid(keyCode: 49, modifiers: twoKeyModifiers), "Key shortcut should accept 2 modifiers")
        check(!ShortcutValidationRules.isValid(keyCode: 49, modifiers: 0), "Key shortcut should reject 0 modifiers")
        check(!ShortcutValidationRules.isValid(keyCode: 49, modifiers: threeKeyModifiers), "Key shortcut should reject 3 modifiers")
        check(!ShortcutValidationRules.isValid(keyCode: 55, modifiers: oneKeyModifier), "Key shortcut should reject modifier key codes")

        let unsupportedBits = oneKeyModifier | (1 << 20)
        check(
            ShortcutValidationRules.filteredModifiers(rawValue: unsupportedBits)
                == ShortcutValidationRules.filteredModifiers(rawValue: oneKeyModifier),
            "Unsupported modifier bits should be filtered"
        )
    }

    private static func testTextCleanupPipeline() {
        let lightInput = "  hello   world!!   this is is   keyscribe  "
        let lightOutput = TextCleanup.process(lightInput, mode: .light)
        check(lightOutput == "Hello world! This is keyscribe", "Light cleanup pipeline normalization failed")

        let aggressiveInput = "i m here\n\n\n\nand dont panic??"
        let aggressiveOutput = TextCleanup.process(aggressiveInput, mode: .aggressive)
        check(aggressiveOutput == "I'm here\n\nAnd don't panic?", "Aggressive cleanup pipeline behavior failed")
    }

    private static func testRecognitionTuningDeterminism() {
        check(abs(RecognitionTuning.clampedFinalizeDelay(0.01) - 0.15) < 0.0001, "Finalize delay lower clamp failed")
        check(abs(RecognitionTuning.clampedFinalizeDelay(0.35) - 0.35) < 0.0001, "Finalize delay nominal value failed")
        check(abs(RecognitionTuning.clampedFinalizeDelay(9.0) - 1.2) < 0.0001, "Finalize delay upper clamp failed")

        let parsed = RecognitionTuning.parseCustomPhrases("alpha, beta\n gamma\n\n,delta")
        check(parsed == ["alpha", "beta", "gamma", "delta"], "Phrase parsing failed")

        let tieWinner = RecognitionTuning.chooseBetterTranscript(primary: "hello", fallback: "abcde")
        check(tieWinner == "hello", "Primary transcript should win deterministic score ties")

        let firstHints = RecognitionTuning.contextualHints(
            defaults: ["alpha", "beta", "alpha", " "],
            custom: ["beta", "gamma", "delta"],
            limit: 4
        )
        let secondHints = RecognitionTuning.contextualHints(
            defaults: ["alpha", "beta", "alpha", " "],
            custom: ["beta", "gamma", "delta"],
            limit: 4
        )
        check(firstHints == ["alpha", "beta", "gamma", "delta"], "Contextual hints ordering/dedup failed")
        check(secondHints == firstHints, "Contextual hints should be deterministic")
    }

    private static func testInsertionRetryPolicyBounds() {
        check(
            InsertionRetryPolicy.plan(for: .copiedOnly, retriesRemaining: 2)
                == .retry(delay: 0.12, nextRetriesRemaining: 1),
            "Copied-only should retry while retries remain"
        )

        check(
            InsertionRetryPolicy.plan(for: .copiedOnly, retriesRemaining: 0)
                == .complete(statusMessage: "Copied to clipboard"),
            "Copied-only should stop with clipboard status when retries are exhausted"
        )

        check(
            InsertionRetryPolicy.plan(for: .notInserted, retriesRemaining: 1)
                == .retry(delay: 0.12, nextRetriesRemaining: 0),
            "Not-inserted should retry while retries remain"
        )

        check(
            InsertionRetryPolicy.plan(for: .notInserted, retriesRemaining: 0)
                == .complete(statusMessage: "Paste unavailable"),
            "Not-inserted should stop with paste-unavailable status when retries are exhausted"
        )

        check(
            InsertionRetryPolicy.plan(for: .copiedOnly, retriesRemaining: -5)
                == .complete(statusMessage: "Copied to clipboard"),
            "Retry input should be bounded at zero to avoid unbounded loops"
        )

        check(
            InsertionRetryPolicy.plan(for: .notInserted, retriesRemaining: 0, debugStatus: "clipboard-write-rejected")
                == .complete(statusMessage: "Paste unavailable [clipboard-write-rejected]"),
            "Final insertion status should include debug details when available"
        )
    }

    private static func testTextInserterClipboardPaths() {
        var callOrder: [String] = []
        let orderedRuntime = TextInserter.Runtime(
            insertDirect: { _ in
                callOrder.append("direct")
                return false
            },
            insertTyping: { _ in
                callOrder.append("typing")
                return false
            },
            writeClipboard: { _ in
                callOrder.append("write")
                return .success(changeCount: 5)
            },
            sendSpecialPaste: {
                callOrder.append("paste")
                return false
            },
            log: { _ in },
            pasteRetryBackoff: [0]
        )

        let orderedOutcome = TextInserter.insertForSmokeTests("hello", copyToClipboard: true, runtime: orderedRuntime)
        check(orderedOutcome.result == .copiedOnly, "Clipboard path should still return copied-only when paste and typing both fail")
        check(callOrder == ["direct", "write", "paste", "typing"], "Copy-enabled flow should prefer clipboard paste before typing fallback")

        var pasteAttempts = 0
        let retryRuntime = TextInserter.Runtime(
            insertDirect: { _ in false },
            insertTyping: { _ in false },
            writeClipboard: { _ in .success(changeCount: 7) },
            sendSpecialPaste: {
                pasteAttempts += 1
                return pasteAttempts == 2
            },
            log: { _ in },
            pasteRetryBackoff: [0, 0]
        )

        let retryOutcome = TextInserter.insertForSmokeTests("hello", copyToClipboard: true, runtime: retryRuntime)
        check(retryOutcome.result == .pasted, "Special paste retry should recover transient paste trigger failures")
        check(pasteAttempts == 2, "Special paste retry should invoke paste trigger until success")

        var restoreCalls = 0
        let temporaryRuntime = TextInserter.Runtime(
            insertDirect: { _ in false },
            insertTyping: { _ in false },
            writeClipboard: { _ in .success(changeCount: 19) },
            sendSpecialPaste: { false },
            captureClipboard: { TextInserter.ClipboardSnapshot() },
            restoreClipboard: { _, _ in
                restoreCalls += 1
            },
            log: { _ in },
            pasteRetryBackoff: [0]
        )

        let temporaryOutcome = TextInserter.insertForSmokeTests("hello", copyToClipboard: false, runtime: temporaryRuntime)
        check(temporaryOutcome.result == .copiedOnly, "Temporary clipboard flow should leave transcript copied if paste fails")
        check(restoreCalls == 0, "Temporary clipboard restore should be skipped when paste does not trigger")

        var restoredChangeCount: Int?
        let restoreRuntime = TextInserter.Runtime(
            insertDirect: { _ in false },
            insertTyping: { _ in false },
            writeClipboard: { _ in .success(changeCount: 33) },
            sendSpecialPaste: { true },
            captureClipboard: { TextInserter.ClipboardSnapshot() },
            restoreClipboard: { _, changeCount in
                restoredChangeCount = changeCount
            },
            log: { _ in },
            pasteRetryBackoff: [0]
        )

        let restoreOutcome = TextInserter.insertForSmokeTests("hello", copyToClipboard: false, runtime: restoreRuntime)
        check(restoreOutcome.result == .pasted, "Temporary clipboard flow should report pasted on successful special paste")
        check(restoredChangeCount == 33, "Temporary clipboard restore should receive the verified clipboard change count")
    }
}
