import Foundation
import Security

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
    private static let minTimeoutSeconds: TimeInterval = 0.25
    private static let maxTimeoutSeconds: TimeInterval = 120

    private let backend: PromptRewriteBackendServing
    private let timeoutSeconds: TimeInterval

    init(
        backend: PromptRewriteBackendServing = BackendPromptRewriteService.shared,
        timeoutSeconds: TimeInterval = 3
    ) {
        self.backend = backend
        self.timeoutSeconds = min(
            max(Self.minTimeoutSeconds, timeoutSeconds),
            Self.maxTimeoutSeconds
        )
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
                    try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
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

    private var timeoutNanoseconds: UInt64 {
        let nanos = timeoutSeconds * 1_000_000_000
        if !nanos.isFinite || nanos <= 0 {
            return UInt64(Self.minTimeoutSeconds * 1_000_000_000)
        }
        if nanos >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(nanos.rounded())
    }
}

private enum PromptRewriteLiveProviderMode: String {
    case openAI = "openai"
    case openRouter = "openrouter"
    case groq = "groq"
    case anthropic = "anthropic"
    case ollama = "ollama"

    var requiresAuthentication: Bool {
        switch self {
        case .ollama:
            return false
        case .openAI, .openRouter, .groq, .anthropic:
            return true
        }
    }

    var supportsOAuthSignIn: Bool {
        switch self {
        case .openAI, .anthropic:
            return true
        case .openRouter, .groq, .ollama:
            return false
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:
            return "gpt-4.1-mini"
        case .openRouter:
            return "openai/gpt-4.1-mini"
        case .groq:
            return "llama-3.3-70b-versatile"
        case .anthropic:
            return "claude-3-5-sonnet-latest"
        case .ollama:
            return "llama3.1"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI:
            return "https://api.openai.com/v1"
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        case .groq:
            return "https://api.groq.com/openai/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        case .ollama:
            return "http://localhost:11434/v1"
        }
    }

    var usesAnthropicMessagesAPI: Bool {
        self == .anthropic
    }

    var settingsProviderMode: PromptRewriteProviderMode {
        switch self {
        case .openAI:
            return .openAI
        case .openRouter:
            return .openRouter
        case .groq:
            return .groq
        case .anthropic:
            return .anthropic
        case .ollama:
            return .ollama
        }
    }
}

private struct PromptRewriteLiveConfiguration {
    let providerMode: PromptRewriteLiveProviderMode
    let openAIModel: String
    let openAIBaseURL: String
    let apiKey: String
    let oauthSession: PromptRewriteOAuthSession?

    var hasCredentials: Bool {
        if let oauthSession {
            return !oauthSession.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    private let openAIProvider: OpenAIPromptRewriteProvider

    init(retrievalService: MemoryRewriteRetrievalService = .shared) {
        self.retrievalService = retrievalService
        self.openAIProvider = .shared
    }

    func retrieveSuggestion(for cleanedTranscript: String) async throws -> PromptRewriteSuggestion? {
        let mode = Self.stubMode
        switch mode {
        case .live:
            do {
                let config = Self.liveConfiguration()
                if config.providerMode.requiresAuthentication && !config.hasCredentials {
                    return nil
                }

                let rewriteContext = try await retrievalService.fetchPromptRewriteContext(
                    for: cleanedTranscript,
                    lessonLimit: 8,
                    cardLimit: 8
                )
                // Do not pay a provider round-trip unless we have an actual rewrite lesson match.
                // Supporting cards alone are too weak and can add latency without improving quality.
                guard !rewriteContext.lessons.isEmpty else { return nil }

                return try await openAIProvider.retrieveSuggestion(
                    for: cleanedTranscript,
                    rewriteContext: rewriteContext,
                    configuration: config
                )
            } catch let backendError as PromptRewriteBackendError {
                throw backendError
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
        let original = event.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggested = event.suggestedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let final = event.finalInsertedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !original.isEmpty,
           !final.isEmpty,
           final.caseInsensitiveCompare(original) != .orderedSame {
            let rationale = feedbackRationale(for: event)
            do {
                try await retrievalService.persistFeedbackRewrite(
                    originalText: original,
                    rewrittenText: final,
                    rationale: rationale,
                    confidence: confidence(for: event.action),
                    timestamp: event.timestamp
                )
            } catch {
                // best effort persistence
            }
        }

        if !original.isEmpty, !suggested.isEmpty {
            switch event.action {
            case .insertedOriginal:
                do {
                    try await retrievalService.invalidateLessonPair(
                        originalText: original,
                        suggestedText: suggested,
                        reason: "User rejected this suggestion and inserted original prompt.",
                        timestamp: event.timestamp
                    )
                } catch {
                    // best effort invalidation
                }
            case .editedThenInserted:
                if !final.isEmpty,
                   final.caseInsensitiveCompare(suggested) != .orderedSame {
                    do {
                        try await retrievalService.invalidateLessonPair(
                            originalText: original,
                            suggestedText: suggested,
                            reason: "Superseded by a better user-edited solution for the same scenario.",
                            timestamp: event.timestamp
                        )
                    } catch {
                        // best effort invalidation
                    }
                }
            case .usedSuggested,
                 .retriedAfterFailure,
                 .insertedOriginalAfterFailure,
                 .canceledAfterFailure:
                break
            }
        }

        guard Self.isDebugLoggingEnabled else { return }
        let action = event.action.rawValue
        let detail = event.failureDetail ?? "none"
        print("[PromptRewriteFeedback] action=\(action) detail=\(detail)")
    }

    private func feedbackRationale(for event: PromptRewriteFeedbackEvent) -> String {
        switch event.action {
        case .usedSuggested:
            return "User accepted suggested rewrite"
        case .editedThenInserted:
            return "User edited suggested rewrite and inserted"
        case .insertedOriginal:
            return "User inserted original text"
        case .retriedAfterFailure:
            return "User retried rewrite after failure"
        case .insertedOriginalAfterFailure:
            return "User inserted original after rewrite failure"
        case .canceledAfterFailure:
            return "User canceled after rewrite failure"
        }
    }

    private func confidence(for action: PromptRewriteFeedbackAction) -> Double {
        switch action {
        case .usedSuggested:
            return 0.95
        case .editedThenInserted:
            return 0.90
        case .insertedOriginal:
            return 0.25
        case .retriedAfterFailure:
            return 0.40
        case .insertedOriginalAfterFailure:
            return 0.20
        case .canceledAfterFailure:
            return 0.10
        }
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

    private static func liveConfiguration() -> PromptRewriteLiveConfiguration {
        let defaults = UserDefaults.standard

        let providerRaw = defaults
            .string(forKey: "KeyScribe.promptRewriteProviderMode")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let providerMode: PromptRewriteLiveProviderMode
        switch providerRaw {
        case "openai":
            providerMode = .openAI
        case "openrouter":
            providerMode = .openRouter
        case "groq":
            providerMode = .groq
        case "anthropic":
            providerMode = .anthropic
        case "ollama (local)", "ollama":
            providerMode = .ollama
        case "local memory", "local-memory", "local":
            providerMode = .openAI
        default:
            providerMode = .openAI
        }

        let model = defaults
            .string(forKey: "KeyScribe.promptRewriteOpenAIModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = defaults
            .string(forKey: "KeyScribe.promptRewriteOpenAIBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let oauthSession = PromptRewriteOAuthCredentialStore.loadSession(for: providerMode.settingsProviderMode)
        var resolvedModel = (model?.isEmpty == false) ? model! : providerMode.defaultModel
        if providerMode == .openAI,
           oauthSession != nil,
           resolvedModel == PromptRewriteLiveProviderMode.openAI.defaultModel {
            // OpenAI OAuth sessions in OpenCode-compatible flow map to Codex models.
            resolvedModel = "gpt-5.3-codex"
        }
        if providerMode == .openAI,
           oauthSession == nil,
           resolvedModel.lowercased().contains("codex") {
            // Codex models are for OAuth/Codex flow and often fail on plain OpenAI API-key chat-completions.
            resolvedModel = PromptRewriteLiveProviderMode.openAI.defaultModel
        }
        let resolvedBaseURL = (baseURL?.isEmpty == false) ? baseURL! : providerMode.defaultBaseURL
        return PromptRewriteLiveConfiguration(
            providerMode: providerMode,
            openAIModel: resolvedModel,
            openAIBaseURL: resolvedBaseURL,
            apiKey: loadProviderAPIKey(for: providerMode),
            oauthSession: oauthSession
        )
    }

    private static func loadProviderAPIKey(for providerMode: PromptRewriteLiveProviderMode) -> String {
        guard providerMode.requiresAuthentication else { return "" }

        if let envValue = ProcessInfo.processInfo.environment["KEYSCRIBE_PROMPT_REWRITE_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty {
            return envValue
        }

        if let envValue = ProcessInfo.processInfo.environment["KEYSCRIBE_OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty {
            return envValue
        }

        let normalizedProviderSlug = providerMode.rawValue
            .lowercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let providerAccount = "prompt-rewrite-provider-api-key.\(normalizedProviderSlug)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.keyscribe.KeyScribe",
            kSecAttrAccount as String: providerAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess, providerMode == .openAI {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.keyscribe.KeyScribe",
                kSecAttrAccount as String: "prompt-rewrite-openai-api-key",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var legacyItem: CFTypeRef?
            let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem)
            guard legacyStatus == errSecSuccess,
                  let legacyData = legacyItem as? Data,
                  let legacyValue = String(data: legacyData, encoding: .utf8) else {
                return ""
            }
            return legacyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if status != errSecSuccess {
            return ""
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor OpenAIPromptRewriteProvider {
    static let shared = OpenAIPromptRewriteProvider()

    private struct ResponsePayload {
        let suggestedText: String
        let memoryContext: String?
        let shouldRewrite: Bool
    }

    private enum ProviderCredential {
        case none
        case apiKey(String)
        case oauth(PromptRewriteOAuthSession)
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func retrieveSuggestion(
        for cleanedTranscript: String,
        rewriteContext: MemoryRewritePromptContext,
        configuration: PromptRewriteLiveConfiguration
    ) async throws -> PromptRewriteSuggestion? {
        guard !rewriteContext.isEmpty else { return nil }

        let lessonPayload = formattedLessonPayload(from: rewriteContext.lessons.prefix(8).map { $0 })
        let supportingCardPayload = formattedSupportingCardPayload(from: rewriteContext.supportingCards.prefix(4).map { $0 })
        let systemPrompt = """
        You improve user prompts using previous prompt-fix memories.
        Prioritize validated mistake->correction lessons over generic memory cards.
        Return strict JSON only with this shape:
        {
          "should_rewrite": boolean,
          "suggested_text": string,
          "memory_context": string
        }
        Rules:
        - Keep user intent unchanged.
        - Do not invent new requirements.
        - If no meaningful rewrite is needed, set should_rewrite=false and suggested_text equal to the original prompt.
        - Prefer lesson entries where validated=true.
        - Apply mistake->correction lessons only when the mistake is actually present or strongly implied.
        - Use supporting cards only as secondary context after lesson matching.
        - memory_context should mention lesson provenance and validation status when relevant.
        - suggested_text must be a fully formatted final response ready to paste.
        - Preserve structural formatting from the original prompt when present (questions, bullet points, numbered lists, markdown sections).
        - Do not collapse list/question formatting into a single paragraph.
        """

        let userPrompt = """
        Original prompt:
        \(cleanedTranscript)

        Rewrite lessons payload (primary):
        \(lessonPayload)

        Supporting memory cards payload (secondary):
        \(supportingCardPayload)
        """

        let credential = try await resolveCredential(for: configuration)
        let request = try buildRequest(
            configuration: configuration,
            credential: credential,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
        let isStreamingCodex = configuration.providerMode == .openAI && isOAuth(credential)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            CrashReporter.logError("Prompt rewrite provider request transport failure: \(error.localizedDescription)")
            throw PromptRewriteBackendError.providerFailure(
                reason: "Provider request failed: \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw PromptRewriteBackendError.providerFailure(reason: "Provider returned an invalid response.")
        }

        if !(200...299).contains(http.statusCode) {
            let detail = providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
            CrashReporter.logError("Prompt rewrite provider request failed status=\(http.statusCode) detail=\(detail)")
            throw PromptRewriteBackendError.providerFailure(
                reason: "Provider request failed (\(http.statusCode)): \(detail)"
            )
        }

        guard let responsePayload = decodeModelResponse(
            data: data,
            originalPrompt: cleanedTranscript,
            providerMode: configuration.providerMode,
            isStreamingCodex: isStreamingCodex
        ) else {
            return nil
        }
        guard responsePayload.shouldRewrite else { return nil }

        let rewritten = responsePayload.suggestedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewritten.isEmpty else { return nil }
        if rewritten.caseInsensitiveCompare(cleanedTranscript) == .orderedSame {
            return nil
        }

        return PromptRewriteSuggestion(
            suggestedText: rewritten,
            memoryContext: synthesizedMemoryContext(
                modelContext: responsePayload.memoryContext,
                lessons: rewriteContext.lessons
            )
        )
    }

    private func buildRequest(
        configuration: PromptRewriteLiveConfiguration,
        credential: ProviderCredential,
        systemPrompt: String,
        userPrompt: String
    ) throws -> URLRequest {
        let endpoint: URL?
        let payload: [String: Any]
        switch configuration.providerMode {
        case .openAI where isOAuth(credential):
            endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")
            payload = [
                "model": configuration.openAIModel,
                "store": false,
                "stream": true,
                "instructions": systemPrompt,
                "input": [
                    [
                        "role": "system",
                        "content": [
                            ["type": "input_text", "text": systemPrompt]
                        ]
                    ],
                    [
                        "role": "user",
                        "content": [
                            ["type": "input_text", "text": userPrompt]
                        ]
                    ]
                ]
            ]
        case .anthropic:
            endpoint = anthropicMessagesEndpoint(from: configuration.openAIBaseURL)
            payload = [
                "model": configuration.openAIModel,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": 0.2,
                "max_tokens": 500
            ]
        case .openAI, .openRouter, .groq, .ollama:
            endpoint = openAICompatibleEndpoint(from: configuration.openAIBaseURL)
            payload = [
                "model": configuration.openAIModel,
                "temperature": 0.2,
                "response_format": ["type": "json_object"],
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]
        }

        guard let endpoint else {
            throw PromptRewriteBackendError.providerFailure(
                reason: "Invalid provider base URL. Update Settings > Memory & Sources > Prompt Rewrite AI."
            )
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let requestBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw PromptRewriteBackendError.providerFailure(reason: "Failed to encode provider request payload.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        switch (configuration.providerMode, credential) {
        case (.anthropic, .oauth(let oauthSession)):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "oauth-2025-04-20,interleaved-thinking-2025-05-14",
                forHTTPHeaderField: "anthropic-beta"
            )
            request.setValue("claude-cli/2.1.2 (external, cli)", forHTTPHeaderField: "User-Agent")
        case (.anthropic, .apiKey(let apiKey)):
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case (.anthropic, .none):
            break
        case (.openAI, .oauth(let oauthSession)):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = oauthSession.accountID,
               !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        case (.openAI, .apiKey(let apiKey)),
             (.openRouter, .apiKey(let apiKey)),
             (.groq, .apiKey(let apiKey)):
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case (.openAI, .none),
             (.openRouter, .none),
             (.groq, .none),
             (.ollama, .none):
            break
        case (.openRouter, .oauth), (.groq, .oauth), (.ollama, .oauth):
            break
        case (.ollama, .apiKey):
            break
        }
        return request
    }

    private func resolveCredential(for configuration: PromptRewriteLiveConfiguration) async throws -> ProviderCredential {
        if let oauthSession = configuration.oauthSession {
            do {
                let refreshed = try await PromptRewriteProviderOAuthService.shared.refreshSessionIfNeeded(
                    oauthSession,
                    providerMode: configuration.providerMode.settingsProviderMode
                )
                return .oauth(refreshed)
            } catch {
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PromptRewriteBackendError.providerFailure(
                    reason: message.isEmpty
                        ? "OAuth session expired. Reconnect the provider in AI Memory Studio."
                        : "OAuth session refresh failed: \(message)"
                )
            }
        }
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            return .apiKey(apiKey)
        }
        return .none
    }

    private func isOAuth(_ credential: ProviderCredential) -> Bool {
        if case .oauth = credential {
            return true
        }
        return false
    }

    private func openAICompatibleEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: normalizedBase + "/chat/completions")
    }

    private func anthropicMessagesEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: normalizedBase + "/messages")
    }

    private func formattedLessonPayload(from lessons: [MemoryRewriteLesson]) -> String {
        guard !lessons.isEmpty else { return "[]" }

        let payload = lessons.map { lesson in
            [
                "mistake": snippet(lesson.mistakeText, limit: 120),
                "correction": snippet(lesson.correctionText, limit: 120),
                "validated": lesson.validationState.isValidated,
                "validation": lesson.validationState.displayName,
                "provenance": lesson.provenance,
                "provider": lesson.provider.displayName,
                "confidence": Double(String(format: "%.2f", lesson.confidence)) ?? lesson.confidence,
                "rationale": snippet(lesson.rationale, limit: 180)
            ] as [String: Any]
        }
        return jsonString(for: payload)
    }

    private func formattedSupportingCardPayload(from cards: [MemoryCard]) -> String {
        guard !cards.isEmpty else { return "[]" }

        let payload = cards.map { card in
            var item: [String: Any] = [
                "provider": card.provider.displayName,
                "title": snippet(card.title, limit: 120),
                "summary": snippet(card.summary, limit: 180),
                "detail": snippet(card.detail, limit: 220),
                "score": Double(String(format: "%.2f", card.score)) ?? card.score
            ]
            let projectContext = supportingCardProjectContext(for: card)
            if let projectName = projectContext.projectName {
                item["project"] = projectName
            }
            if let repositoryName = projectContext.repositoryName {
                item["repository"] = repositoryName
            }
            return item
        }
        return jsonString(for: payload)
    }

    private func supportingCardProjectContext(
        for card: MemoryCard
    ) -> (projectName: String?, repositoryName: String?) {
        let normalizedMetadata = Dictionary(
            uniqueKeysWithValues: card.metadata.map { key, value in
                (key.lowercased(), value)
            }
        )

        let projectKeys = ["project", "project_name", "workspace", "workspace_name", "folder", "cwd", "path", "uri"]
        let repositoryKeys = ["repository", "repository_name", "repo", "repo_name", "git_repository", "git_repo"]

        var projectName = normalizeContextValue(
            firstMetadataValue(keys: projectKeys, metadata: normalizedMetadata)
        )
        var repositoryName = normalizeContextValue(
            firstMetadataValue(keys: repositoryKeys, metadata: normalizedMetadata)
        )

        if projectName == nil || repositoryName == nil {
            let textPath = extractPathLikeValue(from: [card.detail, card.summary, card.title])
            if projectName == nil {
                projectName = derivePathLabel(from: textPath ?? "")
            }
            if repositoryName == nil {
                repositoryName = derivePathLabel(from: textPath ?? "")
            }
        }

        if let projectName,
           let repositoryName,
           projectName.caseInsensitiveCompare(repositoryName) == .orderedSame {
            return (projectName, nil)
        }

        return (projectName, repositoryName)
    }

    private func firstMetadataValue(keys: [String], metadata: [String: String]) -> String? {
        for key in keys {
            let normalizedKey = key.lowercased()
            if let value = metadata[normalizedKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizeContextValue(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        value = value.replacingOccurrences(of: "\\", with: "/")
        if value.hasPrefix("file://"),
           let url = URL(string: value) {
            value = url.path
        }
        if let decoded = value.removingPercentEncoding,
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = decoded
        }

        if value.contains("/") {
            return derivePathLabel(from: value)
        }

        let collapsed = MemoryTextNormalizer.collapsedWhitespace(value)
        guard !collapsed.isEmpty else { return nil }
        let generic: Set<String> = ["workspace", "project", "repository", "repo", "unknown", "state", "storage", "clipboard"]
        guard !generic.contains(collapsed.lowercased()) else { return nil }
        return collapsed
    }

    private func extractPathLikeValue(from texts: [String]) -> String? {
        let patterns = [
            #"file://[^\s"'<>\]\[)\(,;]+"#,
            #"/(?:Users|Volumes|private)/[^\s"'<>\]\[)\(,;]{3,}"#,
            #"[A-Za-z]:\\[^\s"'<>\]\[)\(,;]{3,}"#
        ]

        for text in texts {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                    continue
                }
                let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
                guard let match = regex.firstMatch(in: normalized, options: [], range: range),
                      let matchRange = Range(match.range(at: 0), in: normalized) else {
                    continue
                }
                let token = String(normalized[matchRange])
                let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>,;"))
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return nil
    }

    private func derivePathLabel(from rawPath: String) -> String? {
        let normalized = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { return nil }

        let components = normalized
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        let genericComponents: Set<String> = [
            "users", "user", "library", "application support", "workspace", "workspacestorage",
            "globalstorage", "storage", "state", "session", "sessions", "chat", "history",
            "archives", "archived_sessions", "projects", "repos", "repositories", "repo",
            "memory", "index", "unknown", "tmp", "temp", "active", "default", "clipboard", "worktrees", "worktree",
            ".codex", ".claude", ".opencode",
            "codex", "claude", "opencode", "cursor", "copilot", "windsurf", "codeium", "gemini", "kimi"
        ]

        for component in components.reversed() {
            var candidate = component.removingPercentEncoding ?? component
            candidate = stripTrackerHashSuffix(from: candidate)
            let lowered = candidate.lowercased()
            if isLikelyFilenameComponent(candidate) { continue }
            if genericComponents.contains(lowered) { continue }
            if looksLikeOpaqueIdentifier(candidate) { continue }
            if candidate.count > 96 { continue }
            return candidate
        }
        return nil
    }

    private func stripTrackerHashSuffix(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.lowercased() == "no_repo" {
            return ""
        }

        let parts = trimmed.split(separator: "_")
        guard parts.count >= 2, let last = parts.last else {
            return trimmed
        }

        let lastPart = String(last)
        if lastPart.range(of: "^[0-9a-f]{8,}$", options: .regularExpression) != nil {
            return parts.dropLast().map(String.init).joined(separator: "_")
        }
        return trimmed
    }

    private func isLikelyFilenameComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix(".") {
            return false
        }
        return trimmed.range(of: "\\.[A-Za-z]{1,8}$", options: .regularExpression) != nil
    }

    private func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 12 else { return false }
        if normalized.range(of: "^[0-9a-f]{12,}$", options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: "^[0-9a-f-]{20,}$", options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: "^[0-9a-z_-]{24,}$", options: .regularExpression) != nil,
           normalized.rangeOfCharacter(from: CharacterSet.letters) == nil {
            return true
        }
        return false
    }

    private func jsonString(for object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private func synthesizedMemoryContext(
        modelContext: String?,
        lessons: [MemoryRewriteLesson]
    ) -> String? {
        let normalizedModelContext = modelContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyModelContext = normalizedModelContext?.isEmpty == false ? normalizedModelContext : nil

        guard !lessons.isEmpty || nonEmptyModelContext != nil else {
            return nil
        }

        var parts: [String] = []
        if !lessons.isEmpty {
            let validatedCount = lessons.filter { $0.validationState.isValidated }.count
            let lessonPreview = lessons
                .prefix(2)
                .map { lesson in
                    "[\(lesson.validationState.displayName)] \(snippet(lesson.mistakeText, limit: 28)) -> \(snippet(lesson.correctionText, limit: 36)) (\(lesson.provenance))"
                }
                .joined(separator: "; ")
            parts.append("Lessons considered: \(lessons.count) (\(validatedCount) validated). \(lessonPreview)")
        }

        if let nonEmptyModelContext {
            parts.append("Model context: \(snippet(nonEmptyModelContext, limit: 140))")
        }

        return parts.joined(separator: " ")
    }

    private func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }

    private func decodeModelResponse(
        data: Data,
        originalPrompt: String,
        providerMode: PromptRewriteLiveProviderMode,
        isStreamingCodex: Bool
    ) -> ResponsePayload? {
        let content: String
        if isStreamingCodex {
            content = decodeSSEContent(data: data)
        } else if providerMode.usesAnthropicMessagesAPI {
            content = decodeAnthropicContent(data: data)
        } else {
            content = decodeOpenAICompatibleContent(data: data)
        }

        let cleanedContent = sanitizeModelJSONText(content)
        if let parsed = parseJSONPayload(cleanedContent) {
            return parsed
        }

        let fallback = cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback.isEmpty {
            return nil
        }
        let shouldRewrite = fallback.caseInsensitiveCompare(originalPrompt) != .orderedSame
        return ResponsePayload(
            suggestedText: fallback,
            memoryContext: "\(providerMode.rawValue) rewrite suggestion",
            shouldRewrite: shouldRewrite
        )
    }

    private func decodeOpenAICompatibleContent(data: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              !root.isEmpty else {
            return ""
        }

        if let outputText = root["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        if let output = root["output"] as? [[String: Any]] {
            let flattened = output.compactMap { item -> String? in
                if let content = item["content"] as? [[String: Any]] {
                    let joined = content.compactMap { block -> String? in
                        if let text = block["text"] as? String { return text }
                        if let text = block["output_text"] as? String { return text }
                        return nil
                    }.joined(separator: "\n")
                    if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return joined
                    }
                }
                return nil
            }.joined(separator: "\n")
            if !flattened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return flattened
            }
        }

        guard let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            return ""
        }

        let messageContentValue = message["content"]
        if let contentString = messageContentValue as? String {
            return contentString
        }
        if let contentArray = messageContentValue as? [[String: Any]] {
            return contentArray.compactMap { item in
                if let text = item["text"] as? String { return text }
                if let text = item["content"] as? String { return text }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private func decodeAnthropicContent(data: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let contentArray = root["content"] as? [[String: Any]] else {
            return ""
        }
        return contentArray.compactMap { item in
            if let text = item["text"] as? String {
                return text
            }
            if let text = item["content"] as? String {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    private func decodeSSEContent(data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8) else { return "" }
        var textParts: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data: ") else { continue }
            let jsonString = String(trimmed.dropFirst(6))
            if jsonString == "[DONE]" { continue }
            guard let jsonData = jsonString.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
                continue
            }
            // Responses API streaming: look for output_text.delta
            if let delta = event["delta"] as? String {
                textParts.append(delta)
                continue
            }
            // Also check nested content delta
            if let delta = event["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                textParts.append(text)
                continue
            }
            // Completed event with output_text
            if let outputText = event["output_text"] as? String,
               !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return outputText
            }
            // Check for response.completed with full output
            if let output = event["output"] as? [[String: Any]] {
                let texts = output.compactMap { item -> String? in
                    if let content = item["content"] as? [[String: Any]] {
                        return content.compactMap { $0["text"] as? String }.joined()
                    }
                    return nil
                }
                let joined = texts.joined()
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return joined
                }
            }
        }
        return textParts.joined()
    }

    private func sanitizeModelJSONText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"), trimmed.hasSuffix("```") {
            var body = trimmed
            if body.hasPrefix("```json") {
                body = String(body.dropFirst(7))
            } else {
                body = String(body.dropFirst(3))
            }
            body = String(body.dropLast(3))
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func parseJSONPayload(_ content: String) -> ResponsePayload? {
        guard let data = content.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let shouldRewrite = (object["should_rewrite"] as? Bool)
            ?? (object["shouldRewrite"] as? Bool)
            ?? true
        let suggested = (object["suggested_text"] as? String)
            ?? (object["suggestedText"] as? String)
            ?? (object["rewrite"] as? String)
            ?? (object["output"] as? String)
            ?? ""
        let memoryContext = (object["memory_context"] as? String)
            ?? (object["memoryContext"] as? String)

        let normalizedSuggested = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSuggested.isEmpty else { return nil }

        let normalizedMemoryContext = memoryContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ResponsePayload(
            suggestedText: normalizedSuggested,
            memoryContext: normalizedMemoryContext?.isEmpty == false ? normalizedMemoryContext : nil,
            shouldRewrite: shouldRewrite
        )
    }

    private func providerErrorDetail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let detail = dictionary["detail"] as? String {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let message = dictionary["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let errorString = dictionary["error"] as? String {
            let trimmed = errorString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let error = dictionary["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let detail = error["detail"] as? String {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let code = error["code"] as? String {
                let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
