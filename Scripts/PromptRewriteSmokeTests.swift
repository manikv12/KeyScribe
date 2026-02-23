import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class MockPromptRewriteBackend: PromptRewriteBackendServing {
    var retrieveCallCount = 0
    var feedbackEvents: [PromptRewriteFeedbackEvent] = []
    var retrieveHandler: (String) async throws -> PromptRewriteSuggestion?

    init(retrieveHandler: @escaping (String) async throws -> PromptRewriteSuggestion?) {
        self.retrieveHandler = retrieveHandler
    }

    func retrieveSuggestion(for cleanedTranscript: String) async throws -> PromptRewriteSuggestion? {
        retrieveCallCount += 1
        return try await retrieveHandler(cleanedTranscript)
    }

    func recordFeedback(_ event: PromptRewriteFeedbackEvent) async {
        feedbackEvents.append(event)
    }
}

@main
struct PromptRewriteSmokeTests {
    static func main() async {
        await testSuggestionRetrieval()
        await testNoSuggestion()
        await testTimeoutBehavior()
        await testProviderErrorMapping()
        await testFeedbackForwarding()

        print("PASS: Prompt rewrite smoke tests passed")
    }

    private static func testSuggestionRetrieval() async {
        let backend = MockPromptRewriteBackend { transcript in
            check(transcript == "hello world", "Service should pass the cleaned transcript to backend")
            return PromptRewriteSuggestion(
                suggestedText: "Hello world.",
                memoryContext: "user prefers sentence punctuation"
            )
        }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 1.0)

        do {
            let suggestion = try await service.retrieveSuggestion(for: "hello world")
            check(suggestion?.suggestedText == "Hello world.", "Suggestion text should round-trip from backend")
            check(suggestion?.memoryContext == "user prefers sentence punctuation", "Memory context should be preserved")
            check(backend.retrieveCallCount == 1, "Expected one backend call for suggestion retrieval")
        } catch {
            check(false, "Suggestion retrieval should not throw: \(error)")
        }
    }

    private static func testNoSuggestion() async {
        let backend = MockPromptRewriteBackend { _ in nil }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 1.0)

        do {
            let suggestion = try await service.retrieveSuggestion(for: "leave unchanged")
            check(suggestion == nil, "Expected nil suggestion when backend has no rewrite")
        } catch {
            check(false, "Nil suggestion flow should not throw: \(error)")
        }
    }

    private static func testTimeoutBehavior() async {
        let backend = MockPromptRewriteBackend { _ in
            try await Task.sleep(nanoseconds: 900_000_000)
            return PromptRewriteSuggestion(suggestedText: "slow response", memoryContext: nil)
        }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 0.25)

        do {
            _ = try await service.retrieveSuggestion(for: "time out")
            check(false, "Expected timeout error when backend exceeds timeout")
        } catch let error as PromptRewriteServiceError {
            switch error {
            case .timedOut:
                check(true, "Timed out as expected")
            default:
                check(false, "Expected timeout error, got \(error)")
            }
        } catch {
            check(false, "Expected PromptRewriteServiceError timeout, got \(error)")
        }
    }

    private static func testProviderErrorMapping() async {
        let backend = MockPromptRewriteBackend { _ in
            throw PromptRewriteBackendError.providerFailure(reason: "backend-down")
        }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 1.0)

        do {
            _ = try await service.retrieveSuggestion(for: "trigger error")
            check(false, "Expected provider error mapping")
        } catch let error as PromptRewriteServiceError {
            switch error {
            case let .providerUnavailable(reason):
                check(reason == "backend-down", "Provider failure reason should be preserved")
            default:
                check(false, "Expected providerUnavailable error, got \(error)")
            }
        } catch {
            check(false, "Expected PromptRewriteServiceError providerUnavailable, got \(error)")
        }
    }

    private static func testFeedbackForwarding() async {
        let backend = MockPromptRewriteBackend { _ in nil }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 1.0)

        let event = PromptRewriteFeedbackEvent(
            action: .insertedOriginal,
            originalText: "foo",
            suggestedText: "bar",
            finalInsertedText: "foo",
            failureDetail: nil
        )
        await service.recordFeedback(event)

        check(backend.feedbackEvents.count == 1, "Feedback should be forwarded to backend layer")
        check(backend.feedbackEvents[0].action == .insertedOriginal, "Feedback action should be preserved")
        check(backend.feedbackEvents[0].originalText == "foo", "Feedback original text should be preserved")
    }
}
