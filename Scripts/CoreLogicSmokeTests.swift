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
        testFocusActivationRetryPolicy()
        testTextInsertionDecisionHelpers()

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
    }

    private static func testFocusActivationRetryPolicy() {
        check(
            InsertionRetryPolicy.activationPlan(hasTargetApplication: false, targetIsActive: false, retriesRemaining: 5)
                == .proceed,
            "Activation should proceed immediately when there is no target app"
        )

        check(
            InsertionRetryPolicy.activationPlan(hasTargetApplication: true, targetIsActive: true, retriesRemaining: 5)
                == .proceed,
            "Activation should proceed immediately when target is already active"
        )

        check(
            InsertionRetryPolicy.activationPlan(hasTargetApplication: true, targetIsActive: false, retriesRemaining: 2)
                == .retry(delay: 0.18, nextRetriesRemaining: 1),
            "Activation should retry while inactive target retries remain"
        )

        check(
            InsertionRetryPolicy.activationPlan(hasTargetApplication: true, targetIsActive: false, retriesRemaining: 0)
                == .proceed,
            "Activation should stop retrying once retries are exhausted"
        )
    }

    private static func testTextInsertionDecisionHelpers() {
        let before = TextInserter.VerificationState(
            value: "Hello",
            selectedText: nil,
            selectedRange: NSRange(location: 5, length: 0)
        )

        let afterValueChanged = TextInserter.VerificationState(
            value: "Hello world",
            selectedText: nil,
            selectedRange: NSRange(location: 11, length: 0)
        )

        check(
            TextInserter.didInsertText(" world", before: before, after: afterValueChanged),
            "Value change should count as insertion"
        )

        let afterOnlySelectionMoved = TextInserter.VerificationState(
            value: "Hello",
            selectedText: nil,
            selectedRange: NSRange(location: 11, length: 0)
        )

        check(
            TextInserter.didInsertText(" world", before: before, after: afterOnlySelectionMoved),
            "Caret movement consistent with inserted text should count as insertion"
        )

        let unchanged = TextInserter.VerificationState(
            value: "Hello",
            selectedText: nil,
            selectedRange: NSRange(location: 5, length: 0)
        )

        check(
            !TextInserter.didInsertText(" world", before: before, after: unchanged),
            "Unchanged state should not count as insertion"
        )

        check(
            TextInserter.pasteFallbackDecision(afterPrimaryOutcome: .inserted) == .skipCommandOptionV,
            "Command+Option+V should be skipped after successful primary paste"
        )

        check(
            TextInserter.pasteFallbackDecision(afterPrimaryOutcome: .unverified) == .skipCommandOptionV,
            "Command+Option+V should be skipped when primary paste cannot be verified"
        )

        check(
            TextInserter.pasteFallbackDecision(afterPrimaryOutcome: .notInserted) == .tryCommandOptionV,
            "Command+Option+V should only be attempted after a verified non-insertion"
        )
    }
}
