import Foundation

struct PromptRewriteModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct PromptRewriteModelFetchResult {
    enum Source {
        case remote
        case fallback
    }

    let models: [PromptRewriteModelOption]
    let source: Source
    let message: String?
}

actor PromptRewriteModelCatalogService {
    static let shared = PromptRewriteModelCatalogService()

    private enum Credential {
        case none
        case apiKey(String)
        case oauth(PromptRewriteOAuthSession)
    }

    private enum ModelCatalogError: LocalizedError {
        case invalidBaseURL
        case requestFailed(statusCode: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "Invalid provider base URL."
            case let .requestFailed(statusCode, detail):
                return "Request failed (HTTP \(statusCode)): \(detail)"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchModels(
        providerMode: PromptRewriteProviderMode,
        baseURL: String,
        apiKey: String
    ) async -> PromptRewriteModelFetchResult {
        let fallbackModels = Self.fallbackModels(for: providerMode)
        let credentialResolution = await resolveCredential(
            providerMode: providerMode,
            apiKey: apiKey
        )
        let credential = credentialResolution.credential
        let credentialMessage = credentialResolution.message

        switch providerMode {
        case .openAI:
            if isOAuthCredential(credential) {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Using curated ChatGPT subscription model list."
                )
            }
            guard isAPIKeyCredential(credential) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: credentialMessage ?? "Connect OpenAI to load live models. Showing curated list."
                )
            }
            guard let endpoint = Self.openAIModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Invalid OpenAI base URL. Showing curated list."
                )
            }
            do {
                let models = try await fetchOpenAICompatibleModels(endpoint: endpoint, credential: credential)
                if !models.isEmpty {
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) OpenAI models."
                    )
                }
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "OpenAI returned no models. Showing curated list."
                )
            } catch {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Could not load OpenAI models: \(error.localizedDescription)"
                )
            }
        case .openRouter:
            guard isAPIKeyCredential(credential) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Add OpenRouter API key to load live models. Showing curated list."
                )
            }
            guard let endpoint = Self.openAIModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Invalid OpenRouter base URL. Showing curated list."
                )
            }
            do {
                let models = try await fetchOpenAICompatibleModels(endpoint: endpoint, credential: credential)
                if !models.isEmpty {
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) OpenRouter models."
                    )
                }
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "OpenRouter returned no models. Showing curated list."
                )
            } catch {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Could not load OpenRouter models: \(error.localizedDescription)"
                )
            }
        case .groq:
            guard isAPIKeyCredential(credential) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Add Groq API key to load live models. Showing curated list."
                )
            }
            guard let endpoint = Self.openAIModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Invalid Groq base URL. Showing curated list."
                )
            }
            do {
                let models = try await fetchOpenAICompatibleModels(endpoint: endpoint, credential: credential)
                if !models.isEmpty {
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) Groq models."
                    )
                }
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Groq returned no models. Showing curated list."
                )
            } catch {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Could not load Groq models: \(error.localizedDescription)"
                )
            }
        case .anthropic:
            guard isAPIKeyCredential(credential) || isOAuthCredential(credential) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: credentialMessage ?? "Connect Anthropic to load live models. Showing curated list."
                )
            }
            guard let endpoint = Self.anthropicModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Invalid Anthropic base URL. Showing curated list."
                )
            }
            do {
                let models = try await fetchAnthropicModels(endpoint: endpoint, credential: credential)
                if !models.isEmpty {
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) Anthropic models."
                    )
                }
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Anthropic returned no models. Showing curated list."
                )
            } catch {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Could not load Anthropic models: \(error.localizedDescription)"
                )
            }
        case .ollama:
            guard let openAIEndpoint = Self.openAIModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackModels,
                    source: .fallback,
                    message: "Invalid Ollama base URL. Showing curated list."
                )
            }
            do {
                let models = try await fetchOpenAICompatibleModels(endpoint: openAIEndpoint, credential: .none)
                if !models.isEmpty {
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) Ollama models."
                    )
                }
            } catch {
                // Fall through to /api/tags fallback endpoint.
            }

            if let tagsEndpoint = Self.ollamaTagsEndpoint(from: baseURL) {
                do {
                    let models = try await fetchOllamaTags(endpoint: tagsEndpoint)
                    if !models.isEmpty {
                        return PromptRewriteModelFetchResult(
                            models: models,
                            source: .remote,
                            message: "Loaded \(models.count) Ollama models."
                        )
                    }
                } catch {
                    return PromptRewriteModelFetchResult(
                        models: fallbackModels,
                        source: .fallback,
                        message: "Could not load Ollama models: \(error.localizedDescription)"
                    )
                }
            }

            return PromptRewriteModelFetchResult(
                models: fallbackModels,
                source: .fallback,
                message: "Could not load Ollama models. Showing curated list."
            )
        }
    }

    static func fallbackModels(for providerMode: PromptRewriteProviderMode) -> [PromptRewriteModelOption] {
        switch providerMode {
        case .openAI:
            return buildModelOptions(
                ids: [
                    "gpt-5.3-codex",
                    "gpt-5.2-codex",
                    "gpt-5.1-codex",
                    "gpt-5.1-codex-mini",
                    "gpt-5.1-codex-max",
                    "gpt-4.1-mini"
                ]
            )
        case .openRouter:
            return buildModelOptions(
                ids: [
                    "openai/gpt-4.1-mini",
                    "openai/gpt-5-mini",
                    "anthropic/claude-3.5-sonnet",
                    "google/gemini-2.5-pro",
                    "meta-llama/llama-3.3-70b-instruct"
                ]
            )
        case .groq:
            return buildModelOptions(
                ids: [
                    "llama-3.3-70b-versatile",
                    "llama-3.1-8b-instant",
                    "deepseek-r1-distill-llama-70b",
                    "qwen-qwq-32b"
                ]
            )
        case .anthropic:
            return buildModelOptions(
                ids: [
                    "claude-3-7-sonnet-latest",
                    "claude-3-5-sonnet-latest",
                    "claude-3-5-haiku-latest"
                ]
            )
        case .ollama:
            return buildModelOptions(
                ids: [
                    "llama3.1",
                    "qwen2.5-coder",
                    "deepseek-r1",
                    "mistral"
                ]
            )
        }
    }

    static func parseModelOptions(from data: Data) -> [PromptRewriteModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        var collected: [PromptRewriteModelOption] = []
        collectModelOptions(from: object, into: &collected)
        return normalizeModelOptions(collected)
    }

    static func openAIModelsEndpoint(from baseURL: String) -> URL? {
        guard let normalizedBase = normalizedBaseURL(from: baseURL) else { return nil }
        return URL(string: "\(normalizedBase)/models")
    }

    static func anthropicModelsEndpoint(from baseURL: String) -> URL? {
        guard let normalizedBase = normalizedBaseURL(from: baseURL) else { return nil }
        return URL(string: "\(normalizedBase)/models")
    }

    static func ollamaTagsEndpoint(from baseURL: String) -> URL? {
        guard var normalizedBase = normalizedBaseURL(from: baseURL) else { return nil }
        if normalizedBase.hasSuffix("/v1") {
            normalizedBase = String(normalizedBase.dropLast(3))
        }
        return URL(string: "\(normalizedBase)/api/tags")
    }

    private func resolveCredential(
        providerMode: PromptRewriteProviderMode,
        apiKey: String
    ) async -> (credential: Credential, message: String?) {
        var message: String?
        if providerMode.supportsOAuthSignIn,
           let oauthSession = PromptRewriteOAuthCredentialStore.loadSession(for: providerMode) {
            do {
                let refreshed = try await PromptRewriteProviderOAuthService.shared.refreshSessionIfNeeded(
                    oauthSession,
                    providerMode: providerMode
                )
                return (.oauth(refreshed), nil)
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                if !detail.isEmpty {
                    message = "OAuth refresh failed: \(detail)."
                }
            }
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            return (.apiKey(trimmedKey), message)
        }
        return (.none, message)
    }

    private func fetchOpenAICompatibleModels(
        endpoint: URL,
        credential: Credential
    ) async throws -> [PromptRewriteModelOption] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch credential {
        case .apiKey(let apiKey):
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .oauth(let oauthSession):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
        case .none:
            break
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.requestFailed(statusCode: -1, detail: "invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ModelCatalogError.requestFailed(
                statusCode: http.statusCode,
                detail: providerErrorDetail(from: data) ?? "request failed"
            )
        }
        return Self.parseModelOptions(from: data)
    }

    private func fetchAnthropicModels(
        endpoint: URL,
        credential: Credential
    ) async throws -> [PromptRewriteModelOption] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch credential {
        case .oauth(let oauthSession):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "oauth-2025-04-20,interleaved-thinking-2025-05-14",
                forHTTPHeaderField: "anthropic-beta"
            )
            request.setValue("claude-cli/2.1.2 (external, cli)", forHTTPHeaderField: "User-Agent")
        case .apiKey(let apiKey):
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .none:
            break
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.requestFailed(statusCode: -1, detail: "invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ModelCatalogError.requestFailed(
                statusCode: http.statusCode,
                detail: providerErrorDetail(from: data) ?? "request failed"
            )
        }
        return Self.parseModelOptions(from: data)
    }

    private func fetchOllamaTags(endpoint: URL) async throws -> [PromptRewriteModelOption] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.requestFailed(statusCode: -1, detail: "invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ModelCatalogError.requestFailed(
                statusCode: http.statusCode,
                detail: providerErrorDetail(from: data) ?? "request failed"
            )
        }
        return Self.parseModelOptions(from: data)
    }

    private func providerErrorDetail(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = object as? [String: Any] {
            if let message = dict["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let error = dict["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let error = dict["error"] as? String,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return error
            }
        }
        if let plainText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !plainText.isEmpty {
            return plainText
        }
        return nil
    }

    private static func normalizedBaseURL(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    private static func buildModelOptions(ids: [String]) -> [PromptRewriteModelOption] {
        normalizeModelOptions(
            ids.map { id in
                PromptRewriteModelOption(
                    id: id,
                    displayName: displayName(forModelID: id)
                )
            }
        )
    }

    private static func displayName(forModelID modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return modelID }
        let slashSplit = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        if slashSplit.count == 2 {
            return "\(slashSplit[1]) (\(slashSplit[0]))"
        }
        return trimmed
    }

    private static func collectModelOptions(
        from object: Any,
        into output: inout [PromptRewriteModelOption]
    ) {
        switch object {
        case let text as String:
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            output.append(PromptRewriteModelOption(id: normalized, displayName: normalized))
        case let array as [Any]:
            for item in array {
                collectModelOptions(from: item, into: &output)
            }
        case let dict as [String: Any]:
            let identifier = firstNonEmptyString(
                in: dict,
                keys: ["id", "model", "name", "slug"]
            )
            if let identifier {
                let label = firstNonEmptyString(
                    in: dict,
                    keys: ["display_name", "displayName", "name", "model", "id"]
                ) ?? identifier
                output.append(PromptRewriteModelOption(id: identifier, displayName: label))
            }

            let nestedKeys = ["data", "models", "items", "result"]
            for key in nestedKeys {
                if let nested = dict[key] {
                    collectModelOptions(from: nested, into: &output)
                }
            }
        default:
            break
        }
    }

    private static func firstNonEmptyString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }

    private static func normalizeModelOptions(
        _ options: [PromptRewriteModelOption]
    ) -> [PromptRewriteModelOption] {
        var seen = Set<String>()
        var cleaned: [PromptRewriteModelOption] = []
        cleaned.reserveCapacity(options.count)

        for option in options {
            let normalizedID = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { continue }
            let dedupeKey = normalizedID.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }

            let normalizedDisplayName = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.append(
                PromptRewriteModelOption(
                    id: normalizedID,
                    displayName: normalizedDisplayName.isEmpty ? normalizedID : normalizedDisplayName
                )
            )
        }

        return cleaned.sorted { lhs, rhs in
            let nameCompare = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameCompare == .orderedSame {
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            return nameCompare == .orderedAscending
        }
    }

    private func isAPIKeyCredential(_ credential: Credential) -> Bool {
        if case .apiKey = credential {
            return true
        }
        return false
    }

    private func isOAuthCredential(_ credential: Credential) -> Bool {
        if case .oauth = credential {
            return true
        }
        return false
    }
}
