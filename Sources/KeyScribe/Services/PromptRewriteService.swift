import Foundation

struct PromptRewriteSuggestion: Equatable {
    let suggestedText: String
    let memoryContext: String?
}

enum PromptRewriteFeedbackAction: String, Equatable {
    case usedSuggested = "used-suggested"
    case editedThenInserted = "edited-then-inserted"
    case insertedOriginal = "inserted-original"
    case retriedAfterFailure = "retried-after-failure"
    case insertedOriginalAfterFailure = "inserted-original-after-failure"
    case canceledAfterFailure = "canceled-after-failure"
}

struct PromptRewriteFeedbackEvent {
    let action: PromptRewriteFeedbackAction
    let originalText: String
    let suggestedText: String?
    let finalInsertedText: String?
    let failureDetail: String?
    let timestamp: Date

    init(
        action: PromptRewriteFeedbackAction,
        originalText: String,
        suggestedText: String? = nil,
        finalInsertedText: String? = nil,
        failureDetail: String? = nil,
        timestamp: Date = Date()
    ) {
        self.action = action
        self.originalText = originalText
        self.suggestedText = suggestedText
        self.finalInsertedText = finalInsertedText
        self.failureDetail = failureDetail
        self.timestamp = timestamp
    }
}

protocol PromptRewriteBackendServing {
    func retrieveSuggestion(for cleanedTranscript: String) async throws -> PromptRewriteSuggestion?
    func recordFeedback(_ event: PromptRewriteFeedbackEvent) async
}

enum PromptRewriteBackendError: Error, Equatable {
    case providerFailure(reason: String)
}

enum PromptRewriteServiceError: Error, Equatable {
    case timedOut(timeoutSeconds: TimeInterval)
    case providerUnavailable(reason: String)
}

final class PromptRewriteService {
    static let shared = PromptRewriteService()

    private let backend: PromptRewriteBackendServing
    private let timeoutSeconds: TimeInterval

    init(
        backend: PromptRewriteBackendServing = BackendPromptRewriteService.shared,
        timeoutSeconds: TimeInterval = 5
    ) {
        self.backend = backend
        self.timeoutSeconds = max(0.25, timeoutSeconds)
    }

    func retrieveSuggestion(for cleanedTranscript: String) async throws -> PromptRewriteSuggestion? {
        let normalizedTranscript = cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return nil }

        do {
            return try await withThrowingTaskGroup(of: PromptRewriteSuggestion?.self) { group in
                group.addTask {
                    try await self.backend.retrieveSuggestion(for: normalizedTranscript)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
                    throw PromptRewriteServiceError.timedOut(timeoutSeconds: self.timeoutSeconds)
                }

                let firstResult = try await group.next()
                group.cancelAll()
                return firstResult ?? nil
            }
        } catch let serviceError as PromptRewriteServiceError {
            throw serviceError
        } catch let backendError as PromptRewriteBackendError {
            switch backendError {
            case let .providerFailure(reason):
                throw PromptRewriteServiceError.providerUnavailable(reason: reason)
            }
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                throw PromptRewriteServiceError.providerUnavailable(reason: "unknown-provider-error")
            }
            throw PromptRewriteServiceError.providerUnavailable(reason: detail)
        }
    }

    func recordFeedback(_ event: PromptRewriteFeedbackEvent) async {
        await backend.recordFeedback(event)
    }
}

final class BackendPromptRewriteService: PromptRewriteBackendServing {
    static let shared = BackendPromptRewriteService()

    private enum StubMode: String {
        case live
        case disabled
        case suggest
        case fail
        case timeout
    }

    private let retrievalService: MemoryRewriteRetrievalService

    init(retrievalService: MemoryRewriteRetrievalService = .shared) {
        self.retrievalService = retrievalService
    }

    func retrieveSuggestion(for cleanedTranscript: String) async throws -> PromptRewriteSuggestion? {
        let mode = Self.stubMode
        switch mode {
        case .live:
            do {
                return try await retrievalService.retrieveSuggestion(for: cleanedTranscript)
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PromptRewriteBackendError.providerFailure(
                    reason: detail.isEmpty ? "memory-retrieval-failed" : detail
                )
            }
        case .disabled:
            return nil
        case .suggest:
            let suggestedText = Self.suggestedStubText(fallback: cleanedTranscript)
            guard !suggestedText.isEmpty else { return nil }
            return PromptRewriteSuggestion(
                suggestedText: suggestedText,
                memoryContext: "stubbed-memory-context"
            )
        case .fail:
            throw PromptRewriteBackendError.providerFailure(reason: "stub-provider-failure")
        case .timeout:
            try await Task.sleep(nanoseconds: 15_000_000_000)
            return nil
        }
    }

    func recordFeedback(_ event: PromptRewriteFeedbackEvent) async {
        guard Self.isDebugLoggingEnabled else { return }
        let action = event.action.rawValue
        let detail = event.failureDetail ?? "none"
        print("[PromptRewriteFeedback] action=\(action) detail=\(detail)")
    }

    private static var stubMode: StubMode {
        let raw = ProcessInfo.processInfo.environment["KEYSCRIBE_PROMPT_REWRITE_STUB_MODE"]?.lowercased()
        if raw == nil {
            return .live
        }
        return StubMode(rawValue: raw ?? "") ?? .live
    }

    private static var isDebugLoggingEnabled: Bool {
        ProcessInfo.processInfo.environment["KEYSCRIBE_PROMPT_REWRITE_DEBUG"] == "1"
    }

    private static func suggestedStubText(fallback: String) -> String {
        if let configuredText = ProcessInfo.processInfo.environment["KEYSCRIBE_PROMPT_REWRITE_STUB_TEXT"] {
            let trimmed = configuredText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return fallback
    }
}
