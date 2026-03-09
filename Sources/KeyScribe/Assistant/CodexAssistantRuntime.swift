import Foundation

enum CodexAssistantRuntimeError: Error, LocalizedError {
    case codexMissing
    case runtimeUnavailable(String)
    case requestFailed(String)
    case sessionUnavailable
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .codexMissing:
            return "Codex is not installed on this Mac."
        case .runtimeUnavailable(let message):
            return message
        case .requestFailed(let message):
            return message
        case .sessionUnavailable:
            return "There is no active Codex thread yet."
        case .invalidResponse(let message):
            return message
        }
    }
}

private struct CodexResponsePayload: @unchecked Sendable {
    let raw: Any
}

private enum JSONRPCRequestID: Hashable, Sendable {
    case int(Int)
    case string(String)

    var rawValue: Any {
        switch self {
        case .int(let value):
            return value
        case .string(let value):
            return value
        }
    }
}

private enum CodexIncomingEvent: @unchecked Sendable {
    case notification(method: String, params: [String: Any])
    case serverRequest(id: JSONRPCRequestID, method: String, params: [String: Any])
    case statusMessage(String)
    case processExited(String?)
}

@MainActor
final class CodexAssistantRuntime {
    var onHealthUpdate: (@Sendable (AssistantRuntimeHealth) -> Void)?
    var onTranscript: (@Sendable (AssistantTranscriptEntry) -> Void)?
    var onTimelineMutation: (@Sendable (AssistantTimelineMutation) -> Void)?
    var onHUDUpdate: (@Sendable (AssistantHUDState) -> Void)?
    var onPlanUpdate: (@Sendable ([AssistantPlanEntry]) -> Void)?
    var onToolCallUpdate: (@Sendable ([AssistantToolCallState]) -> Void)?
    var onPermissionRequest: (@Sendable (AssistantPermissionRequest?) -> Void)?
    var onSessionChange: (@Sendable (String?) -> Void)?
    var onStatusMessage: (@Sendable (String?) -> Void)?
    var onAccountUpdate: (@Sendable (AssistantAccountSnapshot) -> Void)?
    var onModelsUpdate: (@Sendable ([AssistantModelOption]) -> Void)?
    var onTokenUsageUpdate: (@Sendable (TokenUsageSnapshot) -> Void)?
    var onRateLimitsUpdate: (@Sendable (AccountRateLimits) -> Void)?
    var onSubagentUpdate: (@Sendable ([SubagentState]) -> Void)?
    var onProposedPlan: (@Sendable (String?) -> Void)?
    /// Fired after the first successful turn of a new session with (sessionID, userPrompt, assistantResponse).
    var onTitleRequest: (@Sendable (_ sessionID: String, _ userPrompt: String, _ assistantResponse: String) -> Void)?

    private var transport: CodexAppServerTransport?
    private var activeSessionID: String?
    private var activeTurnID: String?
    private var preferredModelID: String?
    private var currentCodexPath: String?
    private var currentAccountSnapshot: AssistantAccountSnapshot = .signedOut
    private var currentModels: [AssistantModelOption] = []
    private var toolCalls: [String: AssistantToolCallState] = [:]
    private var liveActivities: [String: AssistantActivityItem] = [:]
    private var pendingPermissionContext: PendingPermissionContext?
    private var loginRefreshTask: Task<Void, Never>?
    private var metadataRefreshTask: Task<Void, Never>?
    private var transportStartupTask: Task<Void, Error>?
    private var turnToolCallCount = 0
    private var sessionTurnCount = 0
    private var firstTurnUserPrompt: String?
    var maxToolCallsPerTurn: Int = 75

    // Title generation: ephemeral thread whose notifications are filtered from the main UI
    private var titleGenThreadID: String?
    private var titleGenBuffer: String = ""
    private var titleGenContinuation: CheckedContinuation<String, Never>?

    // Streaming buffer: accumulates agentMessage deltas into a single growing entry
    private var streamingEntryID: UUID?
    private var streamingBuffer: String = ""
    private var streamingTimelineID: String?
    private var streamingStartedAt: Date?
    private var commentaryTimelineID: String?
    private var commentaryStartedAt: Date?
    private var commentaryBuffer: String = ""
    private var planTimelineID: String?
    private var planStartedAt: Date?

    // Throttle state for high-frequency updates
    private var lastHUDEmitTime: CFAbsoluteTime = 0
    private var lastHUDPhase: AssistantHUDPhase?
    private var pendingHUDState: AssistantHUDState?
    private var hudThrottleItem: DispatchWorkItem?
    private var lastTimelineMutationTime: CFAbsoluteTime = 0
    private var pendingToolCallEmit: DispatchWorkItem?

    // Subagent tracking
    private var activeSubagents: [String: SubagentState] = [:]

    var currentSessionID: String? {
        activeSessionID
    }

    var hasActiveTurn: Bool {
        activeTurnID != nil
    }

    init(preferredModelID: String? = nil) {
        self.preferredModelID = preferredModelID?.nonEmpty
    }

    func setPreferredModelID(_ modelID: String?) {
        preferredModelID = modelID?.nonEmpty
        let health = makeHealth(
            availability: activeTurnID == nil ? .ready : .active,
            summary: currentAccountSnapshot.isLoggedIn ? "Codex is connected" : "Sign in with ChatGPT to use Codex"
        )
        onHealthUpdate?(health)
    }

    func refreshEnvironment(codexPath: String?) async throws -> AssistantEnvironmentDetails {
        currentCodexPath = codexPath?.nonEmpty
        CrashReporter.logInfo("Assistant runtime refresh started codexPath=\(currentCodexPath ?? "missing")")
        try await ensureTransport()
        let health = connectedHealthForCurrentState()
        onHealthUpdate?(health)
        scheduleMetadataRefresh()
        CrashReporter.logInfo("Assistant runtime refresh finished availability=\(health.availability.rawValue) loggedIn=\(currentAccountSnapshot.isLoggedIn) models=\(currentModels.count) deferredMetadata=true")
        return AssistantEnvironmentDetails(health: health, account: currentAccountSnapshot, models: currentModels)
    }

    func startChatGPTLogin() async throws -> URL? {
        try await ensureTransport()

        if currentAccountSnapshot.isLoggedIn {
            _ = try? await refreshModels()
            loginRefreshTask?.cancel()
            onStatusMessage?("Codex is already signed in.")
            onHealthUpdate?(makeHealth(availability: .ready, summary: "Codex is connected"))
            CrashReporter.logInfo("Assistant login skipped because Codex account is already signed in")
            return nil
        }

        let response = try await sendRequest(
            method: "account/login/start",
            params: ["type": "chatgpt"]
        )

        guard let payload = response.raw as? [String: Any] else {
            throw CodexAssistantRuntimeError.invalidResponse("Codex did not return a login response.")
        }

        let loginType = payload["type"] as? String
        let loginID = payload["loginId"] as? String
        let authURL = (payload["authUrl"] as? String).flatMap(URL.init(string:))

        currentAccountSnapshot.loginInProgress = loginType == "chatgpt"
        currentAccountSnapshot.pendingLoginID = loginID
        currentAccountSnapshot.pendingLoginURL = authURL
        onAccountUpdate?(currentAccountSnapshot)
        onStatusMessage?("Finish the ChatGPT sign-in in your browser, then come back to KeyScribe.")
        onHealthUpdate?(makeHealth(availability: .loginRequired, summary: "Waiting for ChatGPT sign-in"))
        CrashReporter.logInfo("Assistant login started loginID=\(loginID ?? "missing") authURLPresent=\(authURL != nil)")
        scheduleLoginRefreshFallback()
        return authURL
    }

    func logout() async throws {
        try await ensureTransport()
        _ = try await sendRequest(method: "account/logout", params: [:])
        loginRefreshTask?.cancel()
        loginRefreshTask = nil
        currentAccountSnapshot = .signedOut
        onAccountUpdate?(currentAccountSnapshot)
        onHealthUpdate?(makeHealth(availability: .loginRequired, summary: "Signed out of Codex"))
    }

    func startNewSession(cwd: String? = nil, preferredModelID: String? = nil) async throws -> String {
        try await ensureTransport()
        toolCalls.removeAll()
        liveActivities.removeAll()
        resetStreamingTimelineState()
        onToolCallUpdate?([])
        onPlanUpdate?([])
        onTimelineMutation?(.reset(sessionID: nil))
        onPermissionRequest?(nil)
        sessionTurnCount = 0
        firstTurnUserPrompt = nil

        let requestedModelID = preferredModelID ?? self.preferredModelID
        CrashReporter.logInfo("Assistant runtime requesting thread/start model=\(requestedModelID ?? "server-default") cwd=\((cwd ?? FileManager.default.homeDirectoryForCurrentUser.path))")

        let response = try await sendRequest(
            method: "thread/start",
            params: threadStartParams(cwd: cwd, modelID: requestedModelID)
        )

        guard let payload = response.raw as? [String: Any],
              let thread = payload["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw CodexAssistantRuntimeError.invalidResponse("Codex did not return a thread id.")
        }

        activeSessionID = threadID
        onSessionChange?(threadID)
        onTranscript?(AssistantTranscriptEntry(role: .system, text: "Started a new Codex thread.", emphasis: true))
        onHealthUpdate?(makeHealth(availability: .active, summary: "Connected"))
        updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
        CrashReporter.logInfo("Assistant runtime thread/start finished threadID=\(threadID)")
        return threadID
    }

    func resumeSession(_ sessionID: String, cwd: String?, preferredModelID: String? = nil) async throws {
        try await ensureTransport()
        _ = try await sendRequest(
            method: "thread/resume",
            params: threadResumeParams(
                threadID: sessionID,
                cwd: cwd,
                modelID: preferredModelID ?? self.preferredModelID
            )
        )

        activeSessionID = sessionID
        sessionTurnCount = 1 // Skip title generation for resumed sessions
        onSessionChange?(sessionID)
        onTranscript?(AssistantTranscriptEntry(role: .system, text: "Loaded Codex thread \(sessionID).", emphasis: true))
        onHealthUpdate?(makeHealth(availability: .active, summary: "Connected"))
        updateHUD(phase: .idle, title: "Thread ready", detail: nil)
    }

    func sendPrompt(
        _ prompt: String,
        attachments: [AssistantAttachment] = [],
        preferredModelID: String? = nil,
        resumeContext: String? = nil,
        memoryContext: String? = nil,
        browserContextOverride: String? = nil
    ) async throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        // Reset plan buffer for the new turn
        proposedPlanBuffer = ""
        allowsProposedPlanForActiveTurn = interactionMode == .plan

        // Track the first user prompt for title generation
        if sessionTurnCount == 0 {
            firstTurnUserPrompt = trimmed
        }

        if activeSessionID == nil {
            _ = try await startNewSession(preferredModelID: preferredModelID ?? self.preferredModelID)
        }

        guard let activeSessionID else {
            throw CodexAssistantRuntimeError.sessionUnavailable
        }

        turnToolCallCount = 0
        updateHUD(phase: .streaming, title: "Codex is working", detail: nil)
        let requestedModelID = preferredModelID ?? self.preferredModelID
        CrashReporter.logInfo("Assistant runtime requesting turn/start threadID=\(activeSessionID) model=\(requestedModelID ?? "server-default") promptChars=\(trimmed.count) attachments=\(attachments.count)")

        let response = try await sendRequest(
            method: "turn/start",
            params: turnStartParams(
                threadID: activeSessionID,
                prompt: trimmed,
                attachments: attachments,
                modelID: requestedModelID,
                resumeContext: resumeContext,
                memoryContext: memoryContext,
                browserContextOverride: browserContextOverride
            )
        )

        if let payload = response.raw as? [String: Any],
           let turn = payload["turn"] as? [String: Any],
           let turnID = turn["id"] as? String {
            activeTurnID = turnID
            CrashReporter.logInfo("Assistant runtime turn/start finished turnID=\(turnID)")
        } else {
            CrashReporter.logWarning("Assistant runtime turn/start finished without a turn id")
        }
    }

    func cancelActiveTurn() async {
        await pendingPermissionContext?.cancel()
        pendingPermissionContext = nil
        onPermissionRequest?(nil)

        guard let activeSessionID, let activeTurnID else {
            updateHUD(phase: .idle, title: "Cancelled", detail: nil)
            return
        }

        do {
            _ = try await sendRequest(
                method: "turn/interrupt",
                params: [
                    "threadId": activeSessionID,
                    "turnId": activeTurnID
                ]
            )
        } catch {
            onStatusMessage?(error.localizedDescription)
        }

        self.activeTurnID = nil
        allowsProposedPlanForActiveTurn = false
        updateHUD(phase: .idle, title: "Cancelled", detail: nil)
    }

    func respondToPermissionRequest(optionID: String) async {
        guard let pendingPermissionContext else { return }
        await pendingPermissionContext.select(optionID: optionID)
        self.pendingPermissionContext = nil
        onPermissionRequest?(nil)
        updateHUD(phase: .acting, title: "Continuing", detail: pendingPermissionContext.request.toolTitle)
    }

    func cancelPendingPermissionRequest() async {
        guard let pendingPermissionContext else { return }
        await pendingPermissionContext.cancel()
        self.pendingPermissionContext = nil
        onPermissionRequest?(nil)
        updateHUD(phase: .idle, title: "Request cancelled", detail: nil)
    }

    /// Detach from the current thread without stopping the transport.
    /// This is available for cases where the UI intentionally wants the next prompt
    /// to start a fresh thread instead of continuing the current one.
    func detachSession() {
        if let oldSessionID = activeSessionID {
            detachedSessionIDs.insert(oldSessionID)
        }
        activeTurnID = nil
        activeSessionID = nil
        toolCalls.removeAll()
        liveActivities.removeAll()
        resetStreamingTimelineState()
        onToolCallUpdate?([])
        onPlanUpdate?([])
        onTimelineMutation?(.reset(sessionID: nil))
    }

    func stop() async {
        loginRefreshTask?.cancel()
        loginRefreshTask = nil
        metadataRefreshTask?.cancel()
        metadataRefreshTask = nil
        transportStartupTask?.cancel()
        transportStartupTask = nil
        await pendingPermissionContext?.cancel()
        pendingPermissionContext = nil
        activeTurnID = nil
        activeSessionID = nil
        toolCalls.removeAll()
        liveActivities.removeAll()
        resetStreamingTimelineState()
        onToolCallUpdate?([])
        onPlanUpdate?([])
        onTimelineMutation?(.reset(sessionID: nil))
        onSessionChange?(nil)
        await transport?.stop()
        transport = nil
        onHealthUpdate?(makeHealth(availability: .idle, summary: "Assistant is idle"))
        updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)

        // Clean up lingering AppleScript processes
        Self.cleanupAppleScriptProcesses()
    }

    private func ensureTransport() async throws {
        if let transport {
            if await transport.isRunning() {
                return
            }
            self.transport = nil
        }

        if let transportStartupTask {
            return try await transportStartupTask.value
        }

        guard let codexPath = currentCodexPath?.nonEmpty else {
            throw CodexAssistantRuntimeError.codexMissing
        }

        onHealthUpdate?(makeHealth(availability: .connecting, summary: "Connecting to Codex App Server"))
        CrashReporter.logInfo("Assistant runtime connecting to Codex App Server path=\(codexPath)")
        let startupTask = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }

            let transport = CodexAppServerTransport { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handleIncomingEvent(event)
                }
            }

            do {
                try await transport.start(codexExecutablePath: codexPath)
                self.transport = transport
                self.onStatusMessage?("Connected to Codex App Server")
                CrashReporter.logInfo("Assistant runtime connected to Codex App Server")
            } catch {
                self.onHealthUpdate?(self.makeHealth(
                    availability: .failed,
                    summary: "Could not start Codex App Server",
                    detail: error.localizedDescription
                ))
                CrashReporter.logError("Assistant runtime failed to start Codex App Server: \(error.localizedDescription)")
                throw error
            }
        }

        transportStartupTask = startupTask

        do {
            try await startupTask.value
            transportStartupTask = nil
        } catch {
            transportStartupTask = nil
            throw error
        }
    }

    private func refreshAccountState() async throws -> AssistantAccountSnapshot {
        CrashReporter.logInfo("Assistant runtime requesting account/read")
        let response = try await requestWithTimeout(method: "account/read", params: ["refreshToken": false])
        let account = parseAccountSnapshot(from: response.raw)
        currentAccountSnapshot = account
        onAccountUpdate?(account)
        CrashReporter.logInfo("Assistant runtime account/read finished loggedIn=\(account.isLoggedIn) authMode=\(account.authMode.rawValue)")
        return account
    }

    func refreshRateLimits() async {
        do {
            let response = try await requestWithTimeout(method: "account/rateLimits/read", params: [:])
            guard let payload = response.raw as? [String: Any] else { return }
            let rateLimits = payload["rateLimits"] as? [String: Any] ?? payload
            handleRateLimitsUpdated(["rateLimits": rateLimits])
        } catch {
            CrashReporter.logInfo("account/rateLimits/read not available: \(error.localizedDescription)")
        }
    }

    private func refreshModels() async throws -> [AssistantModelOption] {
        CrashReporter.logInfo("Assistant runtime requesting model/list")
        let response = try await requestWithTimeout(method: "model/list", params: [:])
        let models = parseModels(from: response.raw)
        currentModels = models
        onModelsUpdate?(models)
        CrashReporter.logInfo("Assistant runtime model/list finished count=\(models.count)")
        return models
    }

    private func requestWithTimeout(
        method: String,
        params: [String: Any],
        timeoutNanoseconds: UInt64 = 8_000_000_000
    ) async throws -> CodexResponsePayload {
        let requestTask = Task { try await sendRequest(method: method, params: params) }

        do {
            return try await withThrowingTaskGroup(of: CodexResponsePayload.self) { group in
                group.addTask {
                    try await requestTask.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw CodexAssistantRuntimeError.runtimeUnavailable("Codex App Server did not answer \(method) in time.")
                }

                let result = try await group.next()
                group.cancelAll()
                return result ?? CodexResponsePayload(raw: [:])
            }
        } catch {
            CrashReporter.logError("Assistant runtime request failed method=\(method) message=\(error.localizedDescription)")
            if case CodexAssistantRuntimeError.runtimeUnavailable = error {
                await transport?.stop()
                transport = nil
                transportStartupTask = nil
            }
            throw error
        }
    }

    private func connectedHealthForCurrentState(detail: String? = nil) -> AssistantRuntimeHealth {
        if activeTurnID != nil {
            return makeHealth(availability: .active, summary: "Codex is working", detail: detail)
        }

        if currentAccountSnapshot.isLoggedIn {
            let resolvedDetail = detail ?? (currentModels.isEmpty ? "Loading model details…" : nil)
            return makeHealth(availability: .ready, summary: "Codex is connected", detail: resolvedDetail)
        }

        let resolvedDetail = detail ?? "Account details are still loading. You can already start chatting."
        return makeHealth(availability: .ready, summary: "Codex App Server is connected", detail: resolvedDetail)
    }

    private func scheduleMetadataRefresh() {
        metadataRefreshTask?.cancel()
        metadataRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var accountError: Error?
            var modelsError: Error?
            var refreshedAccount: AssistantAccountSnapshot?
            var refreshedModels: [AssistantModelOption]?

            do {
                refreshedAccount = try await self.refreshAccountState()
            } catch {
                accountError = error
            }

            do {
                refreshedModels = try await self.refreshModels()
            } catch {
                modelsError = error
            }

            if refreshedAccount?.isLoggedIn == true {
                await self.refreshRateLimits()
            }

            if let refreshedAccount {
                let transportRunning = await self.transport?.isRunning() ?? false
                if modelsError != nil, !transportRunning {
                    let detail = modelsError?.localizedDescription ?? "Codex App Server stopped."
                    self.onHealthUpdate?(self.makeHealth(
                        availability: .idle,
                        summary: "Codex App Server stopped",
                        detail: detail
                    ))
                    CrashReporter.logWarning("Assistant runtime metadata refresh detected stopped transport message=\(detail)")
                    self.metadataRefreshTask = nil
                    return
                }

                let availability: AssistantRuntimeAvailability = refreshedAccount.isLoggedIn
                    ? (self.activeTurnID == nil ? .ready : .active)
                    : .loginRequired
                let summary = refreshedAccount.isLoggedIn ? "Codex is connected" : "Sign in with ChatGPT to use Codex"
                let detail = modelsError?.localizedDescription
                self.onHealthUpdate?(self.makeHealth(availability: availability, summary: summary, detail: detail))
                CrashReporter.logInfo("Assistant runtime metadata refresh finished loggedIn=\(refreshedAccount.isLoggedIn) models=\(refreshedModels?.count ?? self.currentModels.count)")
            } else {
                let detail = accountError?.localizedDescription ?? modelsError?.localizedDescription ?? "Account details are still loading."
                self.onStatusMessage?(detail)
                self.onHealthUpdate?(self.connectedHealthForCurrentState(detail: "Chat is ready, but account details could not be loaded yet."))
                CrashReporter.logWarning("Assistant runtime metadata refresh fell back to transport-only readiness message=\(detail)")
            }

            self.metadataRefreshTask = nil
        }
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> CodexResponsePayload {
        guard let transport else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Codex App Server is not running yet.")
        }
        return try await transport.sendRequest(method: method, params: params)
    }

    private func handleIncomingEvent(_ event: CodexIncomingEvent) async {
        switch event {
        case .statusMessage(let message):
            CrashReporter.logInfo("Assistant runtime status: \(message)")
            onStatusMessage?(message)
        case .processExited(let message):
            activeTurnID = nil
            transport = nil
            transportStartupTask = nil
            CrashReporter.logWarning("Assistant runtime process exited message=\(message ?? "none")")
            onHealthUpdate?(makeHealth(availability: .idle, summary: "Codex App Server stopped", detail: message))
            if let message {
                onTranscript?(AssistantTranscriptEntry(role: .status, text: message))
            }
        case .notification(let method, let params):
            await handleNotification(method: method, params: params)
        case .serverRequest(let id, let method, let params):
            await handleServerRequest(id: id, method: method, params: params)
        }
    }

    private func handleNotification(method: String, params: [String: Any]) async {
        // Intercept notifications from the title-generation thread
        if let titleThread = titleGenThreadID,
           let notifThread = params["threadId"] as? String,
           notifThread == titleThread {
            self.handleTitleGenNotification(method: method, params: params)
            return
        }

        // Drop stale notifications from a detached or mismatched thread.
        // This prevents events from a previous session from leaking into the
        // current session's timeline (e.g. after plan execution switches threads).
        if let notifThread = params["threadId"] as? String {
            if detachedSessionIDs.contains(notifThread) {
                return
            }
            if let currentActive = activeSessionID, notifThread != currentActive {
                return
            }
        }

        switch method {
        case "account/updated":
            CrashReporter.logInfo("Assistant runtime notification account/updated")
            do {
                let account = try await refreshAccountState()
                onHealthUpdate?(makeHealth(
                    availability: account.isLoggedIn ? .ready : .loginRequired,
                    summary: account.isLoggedIn ? "Codex is connected" : "Sign in with ChatGPT to use Codex"
                ))
            } catch {
                onStatusMessage?(error.localizedDescription)
                onHealthUpdate?(makeHealth(
                    availability: .failed,
                    summary: "Codex account check failed",
                    detail: error.localizedDescription
                ))
            }
        case "account/login/completed":
            CrashReporter.logInfo("Assistant runtime notification account/login/completed success=\(params["success"] as? Bool ?? false)")
            let success = params["success"] as? Bool ?? false
            loginRefreshTask?.cancel()
            loginRefreshTask = nil
            currentAccountSnapshot.loginInProgress = false
            currentAccountSnapshot.pendingLoginID = nil
            currentAccountSnapshot.pendingLoginURL = nil
            onAccountUpdate?(currentAccountSnapshot)
            if success {
                do {
                    _ = try await refreshAccountState()
                    _ = try await refreshModels()
                    onTranscript?(AssistantTranscriptEntry(role: .system, text: "ChatGPT sign-in completed.", emphasis: true))
                    onHealthUpdate?(makeHealth(availability: .ready, summary: "Codex is connected"))
                } catch {
                    onStatusMessage?(error.localizedDescription)
                }
            } else {
                let errorText = firstNonEmptyString(params["error"] as? String, "ChatGPT sign-in did not finish.")
                onTranscript?(AssistantTranscriptEntry(role: .error, text: errorText ?? "ChatGPT sign-in did not finish.", emphasis: true))
                onHealthUpdate?(makeHealth(availability: .loginRequired, summary: "Sign in to Codex", detail: errorText))
            }
        case "thread/started":
            CrashReporter.logInfo("Assistant runtime notification thread/started")
            if let threadID = params["threadId"] as? String {
                // Only fire onSessionChange if we haven't already set this session
                // (startNewSession sets it from the response before this notification arrives).
                let alreadyCurrent = activeSessionID == threadID
                activeSessionID = threadID
                if !alreadyCurrent {
                    onSessionChange?(threadID)
                }
            }
        case "thread/status/changed":
            handleThreadStatusChanged(params)
        case "turn/started":
            CrashReporter.logInfo("Assistant runtime notification turn/started")
            if let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String {
                activeTurnID = turnID
            }
            resetStreamingTimelineState()
            updateHUD(phase: .thinking, title: "Thinking", detail: nil)
            onHealthUpdate?(makeHealth(availability: .active, summary: "Codex is working"))
        case "turn/plan/updated":
            onPlanUpdate?(parsePlanEntries(from: params["plan"]))
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String, delta.nonEmpty != nil {
                let channel = (params["channel"] as? String)?.lowercased()
                if channel == "commentary" {
                    appendCommentaryDelta(delta)
                    updateHUD(phase: .acting, title: "Working", detail: delta)
                } else {
                    // Accumulate deltas into a single growing entry
                    if streamingEntryID == nil {
                        streamingEntryID = UUID()
                    }
                    streamingBuffer += delta
                    onTranscript?(AssistantTranscriptEntry(
                        id: streamingEntryID!,
                        role: .assistant,
                        text: streamingBuffer,
                        isStreaming: true
                    ))
                    appendAssistantDelta(delta)
                    updateHUD(phase: .streaming, title: "Codex is responding", detail: nil)
                }
            }
        case "item/plan/delta":
            if allowsProposedPlanForActiveTurn,
               let delta = params["delta"] as? String,
               delta.nonEmpty != nil {
                proposedPlanBuffer += delta
                onProposedPlan?(proposedPlanBuffer)
                emitPlanTimeline(text: proposedPlanBuffer, isStreaming: true)
                updateHUD(phase: .streaming, title: "Building plan", detail: nil)
            }
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let delta = params["delta"] as? String, delta.nonEmpty != nil {
                onTranscript?(AssistantTranscriptEntry(role: .status, text: delta))
                appendCommentaryDelta(delta)
                updateHUD(phase: .thinking, title: "Thinking", detail: delta)
            }
        case "item/started":
            handleItemStartedOrCompleted(params, isCompleted: false)
        case "item/completed":
            handleItemStartedOrCompleted(params, isCompleted: true)
        case "item/commandExecution/outputDelta":
            handleCommandOutputDelta(params)
        case "turn/completed":
            CrashReporter.logInfo("Assistant runtime notification turn/completed")
            activeTurnID = nil
            handleTurnCompleted(params)
        case "error":
            flushStreamingBuffer()
            flushCommentaryBuffer()
            let message = firstNonEmptyString(
                params["message"] as? String,
                extractString(params["error"]),
                "Codex reported an error."
            ) ?? "Codex reported an error."
            onTranscript?(AssistantTranscriptEntry(role: .error, text: message, emphasis: true))
            emitTimelineSystemMessage(message, emphasis: true)
            onHealthUpdate?(makeHealth(availability: .failed, summary: "Codex needs attention", detail: message))
            updateHUD(phase: .failed, title: "Needs attention", detail: message)
            CrashReporter.logError("Assistant runtime error notification: \(message)")
        case "model/rerouted", "configWarning", "deprecationNotice":
            if let message = firstNonEmptyString(
                params["message"] as? String,
                params["warning"] as? String,
                params["title"] as? String
            ) {
                onStatusMessage?(message)
            }
        case "thread/tokenUsage/updated":
            handleTokenUsageUpdated(params)
        case "context/compacted":
            CrashReporter.logInfo("Context compaction completed")
        case "account/rateLimits/updated":
            handleRateLimitsUpdated(params)
        case "item/collabAgentSpawn/begin":
            handleCollabSpawnBegin(params)
        case "item/collabAgentSpawn/end":
            handleCollabSpawnEnd(params)
        case "item/collabAgentInteraction/begin":
            handleCollabInteractionBegin(params)
        case "item/collabAgentInteraction/end":
            handleCollabInteractionEnd(params)
        case "item/collabClose/begin":
            handleCollabClose(params)
        case "item/collabClose/end":
            handleCollabClose(params)
        case "item/collabWaiting/begin":
            handleCollabWaitingBegin(params)
        case "item/collabWaiting/end":
            handleCollabWaitingEnd(params)
        default:
            break
        }
    }

    private func handleTokenUsageUpdated(_ params: [String: Any]) {
        guard let tokenUsage = params["tokenUsage"] as? [String: Any] else { return }

        let lastDict = tokenUsage["last"] as? [String: Any] ?? [:]
        let totalDict = tokenUsage["total"] as? [String: Any] ?? [:]
        let contextWindow = tokenUsage["modelContextWindow"] as? Int

        let snapshot = TokenUsageSnapshot(
            last: TokenUsageBreakdown(from: lastDict) ?? .zero,
            total: TokenUsageBreakdown(from: totalDict) ?? .zero,
            modelContextWindow: contextWindow
        )
        onTokenUsageUpdate?(snapshot)
    }

    // MARK: - Subagent / Collaboration Handlers

    private func handleCollabToolCall(item: [String: Any], status: String) {
        guard let callID = item["id"] as? String else { return }
        let tool = item["tool"] as? String ?? ""
        let agent = item["collabAgent"] as? [String: Any]
        let threadID = agent?["thread_id"] as? String
        let nickname = agent?["agent_nickname"] as? String
        let role = agent?["agent_role"] as? String

        switch tool {
        case "SpawnAgent":
            activeSubagents[callID] = SubagentState(
                id: callID, threadID: threadID, nickname: nickname, role: role,
                status: .spawning, prompt: extractString(item["arguments"])
            )
        case "CloseAgent":
            if let threadID {
                for (key, var agent) in activeSubagents where agent.threadID == threadID {
                    agent.status = .closed
                    activeSubagents[key] = agent
                }
            }
        default:
            break
        }

        if status == "completed" || status == "failed" {
            if var existing = activeSubagents[callID] {
                existing.status = status == "failed" ? .errored : (tool == "CloseAgent" ? .closed : existing.status)
                activeSubagents[callID] = existing
            }
        }

        publishSubagents()
    }

    private func handleCollabSpawnBegin(_ params: [String: Any]) {
        let callID = params["call_id"] as? String ?? params["callId"] as? String ?? UUID().uuidString
        let prompt = params["prompt"] as? String
        activeSubagents[callID] = SubagentState(
            id: callID, threadID: nil, nickname: nil, role: nil,
            status: .spawning, prompt: prompt
        )
        publishSubagents()
        updateHUD(phase: .acting, title: "Spawning agent", detail: prompt)
    }

    private func handleCollabSpawnEnd(_ params: [String: Any]) {
        let callID = params["call_id"] as? String ?? params["callId"] as? String ?? ""
        let threadID = params["new_thread_id"] as? String ?? params["newThreadId"] as? String
        let nickname = params["new_agent_nickname"] as? String ?? params["newAgentNickname"] as? String
        let role = params["new_agent_role"] as? String ?? params["newAgentRole"] as? String

        if var existing = activeSubagents[callID] {
            existing.threadID = threadID
            existing.nickname = nickname
            existing.role = role
            existing.status = .running
            activeSubagents[callID] = existing
        } else {
            activeSubagents[callID] = SubagentState(
                id: callID, threadID: threadID, nickname: nickname, role: role,
                status: .running, prompt: params["prompt"] as? String
            )
        }
        publishSubagents()
    }

    private func handleCollabInteractionBegin(_ params: [String: Any]) {
        let receiverThreadID = params["receiver_thread_id"] as? String ?? params["receiverThreadId"] as? String
        if let receiverThreadID {
            updateSubagentByThread(receiverThreadID, status: .running)
        }
    }

    private func handleCollabInteractionEnd(_ params: [String: Any]) {
        let receiverThreadID = params["receiver_thread_id"] as? String ?? params["receiverThreadId"] as? String
        let statusStr = params["status"] as? String
        if let receiverThreadID {
            let status: SubagentStatus = statusStr == "errored" ? .errored : (statusStr == "completed" ? .completed : .running)
            updateSubagentByThread(receiverThreadID, status: status)
        }
    }

    private func handleCollabClose(_ params: [String: Any]) {
        let receiverThreadID = params["receiver_thread_id"] as? String ?? params["receiverThreadId"] as? String
        if let receiverThreadID {
            updateSubagentByThread(receiverThreadID, status: .closed)
        }
    }

    private func handleCollabWaitingBegin(_ params: [String: Any]) {
        let threadIDs = params["receiver_thread_ids"] as? [String] ?? params["receiverThreadIds"] as? [String] ?? []
        for threadID in threadIDs {
            updateSubagentByThread(threadID, status: .waiting)
        }
        updateHUD(phase: .acting, title: "Waiting for agents", detail: "\(threadIDs.count) agent\(threadIDs.count == 1 ? "" : "s")")
    }

    private func handleCollabWaitingEnd(_ params: [String: Any]) {
        let threadIDs = params["receiver_thread_ids"] as? [String] ?? params["receiverThreadIds"] as? [String] ?? []
        for threadID in threadIDs {
            for (key, var agent) in activeSubagents where agent.threadID == threadID && agent.status == .waiting {
                agent.status = .completed
                activeSubagents[key] = agent
            }
        }
        publishSubagents()
    }

    private func updateSubagentByThread(_ threadID: String, status: SubagentStatus) {
        for (key, var agent) in activeSubagents where agent.threadID == threadID {
            agent.status = status
            activeSubagents[key] = agent
        }
        publishSubagents()
    }

    private func publishSubagents() {
        let sorted = activeSubagents.values.sorted { a, b in
            if a.status.isActive != b.status.isActive { return a.status.isActive }
            return a.id < b.id
        }
        onSubagentUpdate?(Array(sorted))
    }

    private func handleRateLimitsUpdated(_ params: [String: Any]) {
        guard let rateLimits = params["rateLimits"] as? [String: Any] else { return }
        let planType = rateLimits["planType"] as? String
        let primaryDict = rateLimits["primary"] as? [String: Any]
        let secondaryDict = rateLimits["secondary"] as? [String: Any]
        let creditsDict = rateLimits["credits"] as? [String: Any]

        let limits = AccountRateLimits(
            planType: planType,
            primary: RateLimitWindow(from: primaryDict),
            secondary: RateLimitWindow(from: secondaryDict),
            hasCredits: creditsDict?["hasCredits"] as? Bool ?? true,
            unlimited: creditsDict?["unlimited"] as? Bool ?? false
        )
        onRateLimitsUpdate?(limits)
    }

    private func scheduleLoginRefreshFallback() {
        loginRefreshTask?.cancel()
        loginRefreshTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<30 {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }

                do {
                    let account = try await self.refreshAccountState()
                    guard account.isLoggedIn else { continue }

                    _ = try? await self.refreshModels()
                    self.currentAccountSnapshot.loginInProgress = false
                    self.currentAccountSnapshot.pendingLoginID = nil
                    self.currentAccountSnapshot.pendingLoginURL = nil
                    self.onAccountUpdate?(self.currentAccountSnapshot)
                    self.onTranscript?(AssistantTranscriptEntry(role: .system, text: "ChatGPT sign-in completed.", emphasis: true))
                    self.onHealthUpdate?(self.makeHealth(availability: .ready, summary: "Codex is connected"))
                    self.onStatusMessage?("Codex sign-in completed.")
                    self.loginRefreshTask = nil
                    return
                } catch {
                    continue
                }
            }

            guard !Task.isCancelled else { return }
            self.currentAccountSnapshot.loginInProgress = false
            self.onAccountUpdate?(self.currentAccountSnapshot)
            self.onHealthUpdate?(self.makeHealth(
                availability: .loginRequired,
                summary: "Sign in with ChatGPT to use Codex",
                detail: "The sign-in window did not finish yet. You can try again or press Refresh in Setup."
            ))
            self.loginRefreshTask = nil
        }
    }

    private func handleServerRequest(id: JSONRPCRequestID, method: String, params: [String: Any]) async {
        // Auto-decline any tool requests from the title-generation thread
        if let titleThread = titleGenThreadID,
           let notifThread = params["threadId"] as? String,
           notifThread == titleThread {
            do {
                try await transport?.sendResponse(id: id, result: ["decision": "decline"])
            } catch {}
            return
        }

        // In non-agentic modes, auto-decline tool execution requests so the
        // agent can only chat or plan without making changes.
        if interactionMode != .agentic {
            switch method {
            case "item/commandExecution/requestApproval",
                 "item/fileChange/requestApproval":
                do {
                    try await transport?.sendResponse(
                        id: id,
                        result: ["decision": "decline"]
                    )
                } catch {
                    await MainActor.run {
                        onStatusMessage?(error.localizedDescription)
                    }
                }
                let label = method.contains("command") ? "command execution" : "file changes"
                onTranscript?(AssistantTranscriptEntry(
                    role: .system,
                    text: "Declined \(label) — \(interactionMode.label.lowercased()) mode does not allow tool use.",
                    emphasis: false
                ))
                return
            default:
                break
            }
        }

        switch method {
        case "item/commandExecution/requestApproval":
            await presentCommandApprovalRequest(id: id, params: params)
        case "item/fileChange/requestApproval":
            await presentFileChangeApprovalRequest(id: id, params: params)
        case "item/tool/requestUserInput":
            await presentToolUserInputRequest(id: id, params: params)
        case "mcpServer/elicitation/request":
            let message = firstNonEmptyString(
                params["message"] as? String,
                params["prompt"] as? String,
                "Codex needs more information."
            ) ?? "Codex needs more information."
            onTranscript?(AssistantTranscriptEntry(role: .permission, text: message, emphasis: true))
            let request = AssistantPermissionRequest(
                id: approvalRequestID(from: id),
                sessionID: params["threadId"] as? String ?? activeSessionID ?? "",
                toolTitle: "Need more information",
                toolKind: "userInput",
                rationale: message,
                options: [],
                rawPayloadSummary: nil
            )
            onTimelineMutation?(
                .upsert(
                    .permission(
                        id: "permission-\(approvalRequestID(from: id))",
                        sessionID: request.sessionID,
                        turnID: activeTurnID,
                        request: request,
                        createdAt: Date(),
                        source: .runtime
                    )
                )
            )
            onStatusMessage?(message)
        default:
            onStatusMessage?("Codex requested an unsupported action: \(method)")
        }
    }

    private func presentCommandApprovalRequest(id: JSONRPCRequestID, params: [String: Any]) async {
        let command = firstNonEmptyString(params["command"] as? String, "Approve command") ?? "Approve command"
        let reason = firstNonEmptyString(params["reason"] as? String, params["cwd"] as? String)
        let options = [
            AssistantPermissionOption(id: "acceptForSession", title: "Allow for Session", kind: "command", isDefault: true),
            AssistantPermissionOption(id: "accept", title: "Allow Once", kind: "command", isDefault: false),
            AssistantPermissionOption(id: "decline", title: "Decline", kind: "command", isDefault: false),
            AssistantPermissionOption(id: "cancel", title: "Cancel Turn", kind: "command", isDefault: false)
        ]
        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: id),
            sessionID: params["threadId"] as? String ?? activeSessionID ?? "",
            toolTitle: command,
            toolKind: "commandExecution",
            rationale: reason,
            options: options,
            rawPayloadSummary: command
        )
        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: ["decision": optionID]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: ["decision": "cancel"]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        }
        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(role: .permission, text: "Codex wants to run: \(command)", emphasis: true))
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: activeTurnID,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        updateHUD(phase: .waitingForPermission, title: "Approval needed", detail: command)
    }

    private func presentFileChangeApprovalRequest(id: JSONRPCRequestID, params: [String: Any]) async {
        let reason = firstNonEmptyString(params["reason"] as? String, params["grantRoot"] as? String)
        let title = firstNonEmptyString(reason, "Approve file changes") ?? "Approve file changes"
        let options = [
            AssistantPermissionOption(id: "acceptForSession", title: "Allow for Session", kind: "fileChange", isDefault: true),
            AssistantPermissionOption(id: "accept", title: "Allow Once", kind: "fileChange", isDefault: false),
            AssistantPermissionOption(id: "decline", title: "Decline", kind: "fileChange", isDefault: false),
            AssistantPermissionOption(id: "cancel", title: "Cancel Turn", kind: "fileChange", isDefault: false)
        ]
        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: id),
            sessionID: params["threadId"] as? String ?? activeSessionID ?? "",
            toolTitle: "File changes",
            toolKind: "fileChange",
            rationale: title,
            options: options,
            rawPayloadSummary: title
        )
        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: ["decision": optionID]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: ["decision": "cancel"]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        }
        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(role: .permission, text: "Codex wants approval for file changes.", emphasis: true))
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: activeTurnID,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        updateHUD(phase: .waitingForPermission, title: "Approval needed", detail: "File changes")
    }

    private func presentToolUserInputRequest(id: JSONRPCRequestID, params: [String: Any]) async {
        let questions = params["questions"] as? [[String: Any]] ?? []
        let options = questions.flatMap { question -> [AssistantPermissionOption] in
            let questionID = question["id"] as? String ?? UUID().uuidString
            let header = firstNonEmptyString(question["header"] as? String, question["question"] as? String, "Answer") ?? "Answer"
            let questionOptions = question["options"] as? [[String: Any]] ?? []
            return questionOptions.enumerated().map { index, option in
                let label = option["label"] as? String ?? "Continue"
                return AssistantPermissionOption(
                    id: "\(questionID)||\(label)",
                    title: "\(header): \(label)",
                    kind: "userInput",
                    isDefault: index == 0
                )
            }
        }

        guard !options.isEmpty else {
            onStatusMessage?("Codex asked for input that needs a richer form than KeyScribe shows today.")
            return
        }

        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: id),
            sessionID: params["threadId"] as? String ?? activeSessionID ?? "",
            toolTitle: firstNonEmptyString(
                (questions.first?["header"] as? String),
                "Codex needs input"
            ) ?? "Codex needs input",
            toolKind: "userInput",
            rationale: questions.compactMap { $0["question"] as? String }.joined(separator: "\n"),
            options: options,
            rawPayloadSummary: nil
        )

        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }
            let parts = optionID.components(separatedBy: "||")
            guard parts.count == 2 else { return }
            let response: [String: Any] = [
                "answers": [
                    parts[0]: [
                        "answers": [parts[1]]
                    ]
                ]
            ]
            do {
                try await self.transport?.sendResponse(id: id, result: response)
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(id: id, result: ["answers": [:]])
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        }

        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(role: .permission, text: "Codex needs your answer to continue.", emphasis: true))
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: activeTurnID,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        updateHUD(phase: .waitingForPermission, title: "Need input", detail: request.toolTitle)
    }

    private func handleThreadStatusChanged(_ params: [String: Any]) {
        guard let status = params["status"] as? [String: Any] else { return }
        let type = status["type"] as? String ?? ""
        switch type {
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") {
                updateHUD(phase: .waitingForPermission, title: "Waiting for approval", detail: nil)
            } else if flags.contains("waitingOnUserInput") {
                updateHUD(phase: .waitingForPermission, title: "Waiting for input", detail: nil)
            } else {
                updateHUD(phase: .thinking, title: "Working", detail: nil)
            }
        case "idle":
            updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
        case "systemError":
            updateHUD(phase: .failed, title: "Needs attention", detail: nil)
        default:
            break
        }
    }

    /// Finalize the streaming buffer: emit the final non-streaming entry and reset.
    private func flushStreamingBuffer() {
        guard let entryID = streamingEntryID, !streamingBuffer.isEmpty else {
            streamingEntryID = nil
            streamingBuffer = ""
            streamingTimelineID = nil
            streamingStartedAt = nil
            return
        }
        onTranscript?(AssistantTranscriptEntry(
            id: entryID,
            role: .assistant,
            text: streamingBuffer,
            isStreaming: false
        ))
        if let timelineID = streamingTimelineID {
            onTimelineMutation?(
                .upsert(
                    .assistantFinal(
                        id: timelineID,
                        sessionID: activeSessionID,
                        turnID: activeTurnID,
                        text: streamingBuffer,
                        createdAt: streamingStartedAt ?? Date(),
                        updatedAt: Date(),
                        isStreaming: false,
                        source: .runtime
                    )
                )
            )
        }
        streamingEntryID = nil
        streamingBuffer = ""
        streamingTimelineID = nil
        streamingStartedAt = nil
    }

    private func handleItemStartedOrCompleted(_ params: [String: Any], isCompleted: Bool) {
        // Flush any in-progress streaming text before tool cards
        flushStreamingBuffer()
        flushCommentaryBuffer()

        // Handle plan items: finalize the proposed plan when completed
        if isCompleted,
           allowsProposedPlanForActiveTurn,
           let item = params["item"] as? [String: Any],
           let itemType = item["type"] as? String,
           itemType == "plan",
           let text = item["text"] as? String,
           !text.isEmpty {
            proposedPlanBuffer = text
            onProposedPlan?(text)
            emitPlanTimeline(text: text, isStreaming: false)
        }

        guard let item = params["item"] as? [String: Any],
              let state = parseToolCallState(from: item) else {
            return
        }

        if isCompleted {
            toolCalls.removeValue(forKey: state.id)
        } else {
            toolCalls[state.id] = state
        }
        onToolCallUpdate?(toolCalls.values.sorted { $0.title < $1.title })

        if var activity = parseActivityItem(from: item) {
            if let existing = liveActivities[activity.id] {
                if activity.rawDetails?.nonEmpty == nil {
                    activity.rawDetails = existing.rawDetails
                }
                if activity.updatedAt < existing.updatedAt {
                    activity.updatedAt = existing.updatedAt
                }
            }

            if isCompleted {
                if activity.status.isActive {
                    activity.status = .completed
                }
                liveActivities.removeValue(forKey: activity.id)
            } else {
                liveActivities[activity.id] = activity
            }

            onTimelineMutation?(.upsert(.activity(activity)))
        }

        if !isCompleted {
            turnToolCallCount += 1
            if maxToolCallsPerTurn > 0 && turnToolCallCount >= maxToolCallsPerTurn {
                CrashReporter.logInfo("Assistant runtime: tool call limit reached (\(maxToolCallsPerTurn)), auto-cancelling turn")
                onTranscript?(AssistantTranscriptEntry(
                    role: .system,
                    text: "Reached the tool call limit (\(maxToolCallsPerTurn)). Turn was automatically stopped.",
                    emphasis: true
                ))
                emitTimelineSystemMessage("Reached the tool call limit (\(maxToolCallsPerTurn)). Turn was automatically stopped.", emphasis: true)
                Task { [weak self] in await self?.cancelActiveTurn() }
                return
            }
            updateHUD(phase: .acting, title: state.title, detail: state.hudDetail ?? state.detail)
        }
    }

    private func handleCommandOutputDelta(_ params: [String: Any]) {
        guard let itemID = params["itemId"] as? String,
              let delta = params["delta"] as? String,
              delta.nonEmpty != nil else {
            return
        }

        if var existing = toolCalls[itemID] {
            let current = existing.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            existing.detail = current.isEmpty ? delta : "\(current)\n\(delta)"
            toolCalls[itemID] = existing
            // Throttle tool call list pushes for output deltas (arrive very rapidly)
            if pendingToolCallEmit == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.onToolCallUpdate?(self.toolCalls.values.sorted { $0.title < $1.title })
                    self.pendingToolCallEmit = nil
                }
                pendingToolCallEmit = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
            }
        }

        if var activity = liveActivities[itemID] {
            let current = activity.rawDetails?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            activity.rawDetails = current.isEmpty ? delta : "\(current)\n\(delta)"
            activity.updatedAt = Date()
            liveActivities[itemID] = activity
            onTimelineMutation?(.upsert(.activity(activity)))
        }
    }

    private func handleTurnCompleted(_ params: [String: Any]) {
        let responsePreview = streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        flushStreamingBuffer()
        flushCommentaryBuffer()
        defer { allowsProposedPlanForActiveTurn = false }

        guard let turn = params["turn"] as? [String: Any] else {
            updateHUD(phase: .success, title: "Finished", detail: responsePreview)
            return
        }

        let status = turn["status"] as? String ?? "completed"
        switch status {
        case "completed":
            finalizeActiveActivities(with: .completed)
            onTranscript?(AssistantTranscriptEntry(role: .status, text: "Codex finished this turn."))
            updateHUD(phase: .success, title: "Finished", detail: responsePreview)
            onHealthUpdate?(makeHealth(availability: .ready, summary: "Codex is connected"))

            // After the first successful turn, request an AI-generated session title
            if sessionTurnCount == 0,
               let sessionID = activeSessionID,
               let userPrompt = firstTurnUserPrompt,
               !streamingBuffer.isEmpty {
                let response = streamingBuffer
                onTitleRequest?(sessionID, userPrompt, response)
            }
            sessionTurnCount += 1
        case "interrupted":
            finalizeActiveActivities(with: .interrupted)
            onTranscript?(AssistantTranscriptEntry(role: .status, text: "This turn was interrupted."))
            emitTimelineSystemMessage("This turn was interrupted.")
            updateHUD(phase: .idle, title: "Interrupted", detail: nil)
            onHealthUpdate?(makeHealth(availability: .ready, summary: "Codex is connected"))
        case "failed":
            finalizeActiveActivities(with: .failed)
            let errorText = extractString((turn["error"] as? [String: Any])?["message"]) ?? "Codex could not finish this turn."
            onTranscript?(AssistantTranscriptEntry(role: .error, text: errorText, emphasis: true))
            emitTimelineSystemMessage(errorText, emphasis: true)
            updateHUD(phase: .failed, title: "Needs attention", detail: errorText)
            onHealthUpdate?(makeHealth(availability: .failed, summary: "Codex needs attention", detail: errorText))
        default:
            updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
        }

        // Clean up any lingering AppleScript/osascript processes spawned during the turn
        Self.cleanupAppleScriptProcesses()
    }

    /// Kills lingering `osascript` processes and resets `System Events` memory
    /// by sending it a quit signal (macOS relaunches it on demand).
    static func cleanupAppleScriptProcesses() {
        DispatchQueue.global(qos: .utility).async {
            // Kill any orphaned osascript processes
            let killOsa = Process()
            killOsa.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killOsa.arguments = ["-9", "osascript"]
            killOsa.standardOutput = FileHandle.nullDevice
            killOsa.standardError = FileHandle.nullDevice
            try? killOsa.run()
            killOsa.waitUntilExit()

            // Reset System Events to reclaim memory (macOS auto-restarts it on next use)
            let resetSE = Process()
            resetSE.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            resetSE.arguments = ["System Events"]
            resetSE.standardOutput = FileHandle.nullDevice
            resetSE.standardError = FileHandle.nullDevice
            try? resetSE.run()
            resetSE.waitUntilExit()
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        if streamingTimelineID == nil {
            streamingTimelineID = "assistant-final-\(UUID().uuidString)"
            streamingStartedAt = Date()
        }

        guard let timelineID = streamingTimelineID else { return }

        // Throttle timeline mutations to ~12Hz during streaming to reduce view invalidation
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastTimelineMutationTime >= 0.08 else { return }
        lastTimelineMutationTime = now

        onTimelineMutation?(
            .upsert(
                .assistantFinal(
                    id: timelineID,
                    sessionID: activeSessionID,
                    turnID: activeTurnID,
                    text: streamingBuffer,
                    createdAt: streamingStartedAt ?? Date(),
                    updatedAt: Date(),
                    isStreaming: true,
                    source: .runtime
                )
            )
        )
    }

    private func appendCommentaryDelta(_ delta: String) {
        if commentaryTimelineID == nil {
            commentaryTimelineID = "assistant-progress-\(UUID().uuidString)"
            commentaryStartedAt = Date()
        }

        commentaryBuffer += delta
        guard let commentaryTimelineID else { return }
        onTimelineMutation?(
            .upsert(
                .assistantProgress(
                    id: commentaryTimelineID,
                    sessionID: activeSessionID,
                    turnID: activeTurnID,
                    text: commentaryBuffer,
                    createdAt: commentaryStartedAt ?? Date(),
                    updatedAt: Date(),
                    isStreaming: true,
                    source: .runtime
                )
            )
        )
    }

    private func flushCommentaryBuffer() {
        guard let commentaryTimelineID, !commentaryBuffer.isEmpty else {
            commentaryTimelineID = nil
            commentaryStartedAt = nil
            commentaryBuffer = ""
            return
        }

        onTimelineMutation?(
            .upsert(
                .assistantProgress(
                    id: commentaryTimelineID,
                    sessionID: activeSessionID,
                    turnID: activeTurnID,
                    text: commentaryBuffer,
                    createdAt: commentaryStartedAt ?? Date(),
                    updatedAt: Date(),
                    isStreaming: false,
                    source: .runtime
                )
            )
        )

        self.commentaryTimelineID = nil
        self.commentaryStartedAt = nil
        self.commentaryBuffer = ""
    }

    private func emitPlanTimeline(text: String, isStreaming: Bool) {
        if planTimelineID == nil {
            planTimelineID = "plan-\(activeTurnID ?? UUID().uuidString)"
            planStartedAt = Date()
        }

        guard let planTimelineID else { return }
        onTimelineMutation?(
            .upsert(
                .plan(
                    id: planTimelineID,
                    sessionID: activeSessionID,
                    turnID: activeTurnID,
                    text: text,
                    entries: planEntriesSnapshot(from: text),
                    createdAt: planStartedAt ?? Date(),
                    updatedAt: Date(),
                    isStreaming: isStreaming,
                    source: .runtime
                )
            )
        )
    }

    private func emitTimelineSystemMessage(_ text: String, emphasis: Bool = false) {
        guard let text = text.nonEmpty else { return }
        onTimelineMutation?(
            .upsert(
                .system(
                    sessionID: activeSessionID,
                    turnID: activeTurnID,
                    text: text,
                    createdAt: Date(),
                    emphasis: emphasis,
                    source: .runtime
                )
            )
        )
    }

    private func finalizeActiveActivities(with status: AssistantActivityStatus) {
        let now = Date()
        for activity in liveActivities.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            var finalized = activity
            finalized.status = status
            finalized.updatedAt = now
            onTimelineMutation?(.upsert(.activity(finalized)))
        }
        liveActivities.removeAll()
        toolCalls.removeAll()
        onToolCallUpdate?([])
    }

    private func resetStreamingTimelineState() {
        streamingEntryID = nil
        streamingBuffer = ""
        streamingTimelineID = nil
        streamingStartedAt = nil
        commentaryTimelineID = nil
        commentaryStartedAt = nil
        commentaryBuffer = ""
        planTimelineID = nil
        planStartedAt = nil
        proposedPlanBuffer = ""
        allowsProposedPlanForActiveTurn = false
        lastTimelineMutationTime = 0
    }

    private func parseActivityItem(from item: [String: Any]) -> AssistantActivityItem? {
        guard let state = parseToolCallState(from: item) else { return nil }

        let rawKind = item["type"] as? String ?? state.kind ?? "other"
        let kind = activityKind(from: rawKind)
        let status = parsedActivityStatus(from: state.status, fallback: .running)
        let details = firstNonEmptyString(
            state.detail,
            item["command"] as? String,
            (item["action"] as? String),
            ((item["action"] as? [String: Any])?["query"] as? String),
            extractString(item["arguments"]),
            extractString(item["result"])
        )

        return AssistantActivityItem(
            id: state.id,
            sessionID: activeSessionID,
            turnID: activeTurnID,
            kind: kind,
            title: state.title,
            status: status,
            friendlySummary: activitySummary(kind: kind, title: state.title),
            rawDetails: compactDetail(details),
            startedAt: liveActivities[state.id]?.startedAt ?? Date(),
            updatedAt: Date(),
            source: .runtime
        )
    }

    private func activityKind(from rawValue: String?) -> AssistantActivityKind {
        switch rawValue {
        case "commandExecution":
            return .commandExecution
        case "fileChange":
            return .fileChange
        case "webSearch":
            return .webSearch
        case "browserAutomation":
            return .browserAutomation
        case "mcpToolCall":
            return .mcpToolCall
        case "dynamicToolCall":
            return .dynamicToolCall
        case "collabAgentToolCall":
            return .subagent
        case "reasoning":
            return .reasoning
        default:
            return .other
        }
    }

    private func parsedActivityStatus(
        from rawValue: String?,
        fallback: AssistantActivityStatus
    ) -> AssistantActivityStatus {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return fallback
        }

        switch rawValue {
        case "pending":
            return .pending
        case "waiting":
            return .waiting
        case "completed", "complete", "succeeded", "success":
            return .completed
        case "failed", "errored", "error":
            return .failed
        case "interrupted", "cancelled", "canceled":
            return .interrupted
        case "inprogress", "in_progress", "running", "working", "active", "started":
            return .running
        default:
            return fallback
        }
    }

    private func activitySummary(kind: AssistantActivityKind, title: String) -> String {
        switch kind {
        case .commandExecution:
            return "Ran a terminal command."
        case .fileChange:
            return "Edited files in the workspace."
        case .webSearch:
            return "Searched the web."
        case .browserAutomation:
            return "Used the browser."
        case .mcpToolCall:
            return "Used an MCP tool."
        case .dynamicToolCall:
            return "Used \(title)."
        case .subagent:
            return "Worked with a subagent."
        case .reasoning:
            return "Thought through the task."
        case .other:
            return "Ran a tool."
        }
    }

    private func planEntriesSnapshot(from text: String) -> [AssistantPlanEntry]? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        return lines.map { AssistantPlanEntry(content: $0, status: "pending") }
    }

    private func parsePlanEntries(from raw: Any?) -> [AssistantPlanEntry] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.map { row in
            AssistantPlanEntry(
                content: row["step"] as? String ?? "Plan step",
                status: row["status"] as? String ?? "pending"
            )
        }
    }

    private func parseToolCallState(from item: [String: Any]) -> AssistantToolCallState? {
        guard let id = item["id"] as? String else { return nil }
        let type = item["type"] as? String ?? "work"
        guard shouldRenderActivity(for: type) else { return nil }
        let status = item["status"] as? String ?? "inProgress"

        switch type {
        case "commandExecution":
            let command = firstNonEmptyString(item["command"] as? String, "Command") ?? "Command"
            return AssistantToolCallState(
                id: id,
                title: "Command",
                kind: type,
                status: status,
                detail: compactDetail(command),
                hudDetail: friendlyCommandSummary(command)
            )
        case "fileChange":
            let changeCount = (item["changes"] as? [[String: Any]])?.count ?? 0
            let detail = changeCount > 0 ? "\(changeCount) file change\(changeCount == 1 ? "" : "s")" : "Applying file changes"
            return AssistantToolCallState(
                id: id,
                title: "File Changes",
                kind: type,
                status: status,
                detail: detail
            )
        case "mcpToolCall":
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "tool"
            return AssistantToolCallState(
                id: id,
                title: "\(server): \(tool)",
                kind: type,
                status: status,
                detail: compactDetail(extractString(item["arguments"]))
            )
        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "Tool"
            return AssistantToolCallState(
                id: id,
                title: tool,
                kind: type,
                status: status,
                detail: compactDetail(extractString(item["arguments"]))
            )
        case "webSearch":
            return AssistantToolCallState(id: id, title: "Web Search", kind: type, status: status, detail: nil)
        case "browserAutomation":
            let action = item["action"] as? String ?? "Browser action"
            return AssistantToolCallState(id: id, title: "Browser", kind: type, status: status, detail: compactDetail(action))
        case "collabAgentToolCall":
            handleCollabToolCall(item: item, status: status)
            let tool = item["tool"] as? String ?? "collab"
            let nickname = (item["collabAgent"] as? [String: Any])?["agent_nickname"] as? String
            let detail = nickname ?? tool
            return AssistantToolCallState(id: id, title: "Subagent", kind: type, status: status, detail: detail)
        default:
            return AssistantToolCallState(
                id: id,
                title: type.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).capitalized,
                kind: type,
                status: status,
                detail: compactDetail(extractString(item["result"]))
            )
        }
    }

    func shouldRenderActivity(for rawType: String) -> Bool {
        switch rawType {
        case "agentMessage", "assistantMessage", "message", "plan", "reasoning", "userMessage":
            return false
        default:
            return true
        }
    }

    private func parseAccountSnapshot(from raw: Any) -> AssistantAccountSnapshot {
        guard let payload = raw as? [String: Any] else {
            return .signedOut
        }

        let requiresOpenAIAuth = payload["requiresOpenaiAuth"] as? Bool ?? false
        guard let account = payload["account"] as? [String: Any],
              let type = account["type"] as? String else {
            return AssistantAccountSnapshot(
                authMode: .none,
                email: nil,
                planType: nil,
                requiresOpenAIAuth: requiresOpenAIAuth,
                loginInProgress: false,
                pendingLoginURL: nil,
                pendingLoginID: nil
            )
        }

        let authMode: AssistantAccountAuthMode
        switch type {
        case "chatgpt":
            authMode = .chatGPT
        case "apiKey":
            authMode = .apiKey
        default:
            authMode = .none
        }

        return AssistantAccountSnapshot(
            authMode: authMode,
            email: account["email"] as? String,
            planType: account["planType"] as? String,
            requiresOpenAIAuth: requiresOpenAIAuth,
            loginInProgress: currentAccountSnapshot.loginInProgress,
            pendingLoginURL: currentAccountSnapshot.pendingLoginURL,
            pendingLoginID: currentAccountSnapshot.pendingLoginID
        )
    }

    private func parseModels(from raw: Any) -> [AssistantModelOption] {
        guard let payload = raw as? [String: Any],
              let rows = payload["data"] as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let efforts: [String] = (row["supportedReasoningEfforts"] as? [[String: Any]])?.compactMap {
                $0["reasoningEffort"] as? String
            } ?? []
            return AssistantModelOption(
                id: id,
                displayName: firstNonEmptyString(row["displayName"] as? String, id) ?? id,
                description: firstNonEmptyString(row["description"] as? String, row["model"] as? String, id) ?? id,
                isDefault: row["isDefault"] as? Bool ?? false,
                hidden: row["hidden"] as? Bool ?? false,
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: row["defaultReasoningEffort"] as? String
            )
        }
    }

    var browserProfileContext: [String: String]?
    var customInstructions: String?
    var reasoningEffort: String?
    var interactionMode: AssistantInteractionMode = .agentic

    // Proposed plan streaming: accumulates item/plan/delta content
    private var proposedPlanBuffer: String = ""
    private var allowsProposedPlanForActiveTurn = false

    /// Session IDs that have been detached. Notifications from these sessions are dropped.
    private var detachedSessionIDs: Set<String> = []

    private func threadStartParams(cwd: String?, modelID: String?) -> [String: Any] {
        var params: [String: Any] = [
            "approvalPolicy": "on-request",
            "sandbox": "danger-full-access",
            "personality": "friendly",
            "serviceName": "KeyScribe",
            "ephemeral": false
        ]
        params["cwd"] = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        if let modelID = modelID?.nonEmpty {
            params["model"] = modelID
        }
        let instructions = buildInstructions()
        if !instructions.isEmpty {
            params["instructions"] = instructions
        }

        // Include collaborationMode at thread start so the server knows the
        // base behavior for this thread. Turn-level overrides can still switch
        // a specific prompt into plan mode when needed.
        if let effectiveModel = (modelID?.nonEmpty ?? preferredModelID)?.nonEmpty {
            var modeSettings: [String: Any] = ["model": effectiveModel]
            if let effort = reasoningEffort?.nonEmpty {
                modeSettings["reasoningEffort"] = effort
            }
            params["collaborationMode"] = [
                "mode": interactionMode.codexModeKind,
                "settings": modeSettings
            ] as [String: Any]
        }

        return params
    }

    private func buildInstructions() -> String {
        var sections: [String] = []

        switch interactionMode {
        case .conversational:
            sections.append("""
            # Conversational Mode

            You are in conversational mode. Reply with normal helpful text.
            Do NOT propose or output a structured plan, checklist, outline, or step-by-step implementation plan in this mode.
            Do NOT take action or present yourself as executing work in this mode.
            """)
        case .plan:
            sections.append("""
            # Plan Mode

            You are in plan mode. Produce a clear plan only.
            Do NOT claim to have already executed the work.
            Do NOT take action or present tool results as if the work is done.
            Keep the output focused on the proposed plan so the user can review it before execution.
            """)
        case .agentic:
            break
        }

        // When browser automation is configured with a user profile, place the
        // MCP-tool ban at the very top so it is the first thing the model reads.
        if browserProfileContext != nil {
            sections.append("""
            # CRITICAL: Browser Tool Restriction

            You MUST NOT call any MCP-provided browser tools such as `browser_navigate`, `browser_run_code`, `browser_click`, `browser_snapshot`, or any tool whose name starts with `playwright:` or `browser_`. These tools do not use the user's configured browser profile and will open a separate, unauthenticated browser. Instead, use osascript (AppleScript) or Playwright scripts as described in the Browser Automation section below.
            """)
        }

        if let custom = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            sections.append("# Custom Instructions\n\n\(custom)")
        }
        if let browser = browserInstructions() {
            sections.append(browser)
        }
        return sections.joined(separator: "\n\n")
    }

    private func browserInstructions() -> String? {
        guard let ctx = browserProfileContext,
              let browser = ctx["browser"],
              let channel = ctx["channel"],
              let profileDir = ctx["profileDir"],
              let userDataDir = ctx["userDataDir"] else {
            return nil
        }

        let profilePath = "\(userDataDir)/\(profileDir)"
        let escapedProfilePath = profilePath.replacingOccurrences(of: "'", with: "\\'")

        let launchOptions: String
        if channel == "brave" {
            launchOptions = """
                headless: false,
                executablePath: '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
            """
        } else {
            launchOptions = """
                headless: false,
                channel: '\(channel)',
            """
        }

        let appName: String
        if channel == "brave" {
            appName = "Brave Browser"
        } else {
            appName = "Google Chrome"
        }

        return """
        # Browser Automation

        You have access to browser automation for the user's \(browser) browser (profile: "\(ctx["profileName"] ?? "Default")"). This means you can access their existing login sessions, cookies, and bookmarks.

        **DO NOT use any MCP browser tools** (e.g. `playwright:browser_navigate`, `playwright:browser_run_code`, or any other MCP-provided browser automation tools). They do not use the user's configured browser profile. Use one of the two approaches below instead.

        ## Option 1: AppleScript / osascript (preferred for simple tasks)

        For quick tasks like reading page content, navigating, or extracting text, use osascript to interact with the already-open browser. This is faster and does not require installing anything.

        ```bash
        # Open a URL in the user's browser
        osascript -e 'tell application "\(appName)" to open location "https://example.com"'

        # Get the URL and title of the active tab
        osascript -e 'tell application "\(appName)" to tell active tab of front window to return {URL, title}'

        # Read page text from the active tab
        osascript -e 'tell application "\(appName)" to tell active tab of front window to execute javascript "document.body.innerText.slice(0, 5000)"'

        # Execute JavaScript and get results
        osascript -e 'tell application "\(appName)" to tell active tab of front window to execute javascript "JSON.stringify({url: location.href, title: document.title})"'

        # Click or interact via JavaScript
        osascript -e 'tell application "\(appName)" to tell active tab of front window to execute javascript "document.querySelector(\\'button.submit\\').click()"'
        ```

        ## Option 2: Playwright scripts (for complex multi-step automation)

        For complex tasks that need reliable element selection, waiting, or multi-page flows, use Playwright with the user's browser profile.

        Setup (one time per session):
        ```bash
        cd /tmp && mkdir -p keyscribe-pw && cd keyscribe-pw && [ -d node_modules/playwright-core ] || npm init -y --silent && npm install playwright-core --silent
        ```

        Write a .mjs script and run it with node:
        ```javascript
        // save as /tmp/keyscribe-pw/task.mjs
        import { chromium } from 'playwright-core';

        const context = await chromium.launchPersistentContext(
          '\(escapedProfilePath)',
          {
        \(launchOptions)    args: ['--disable-blink-features=AutomationControlled', '--no-first-run', '--no-default-browser-check'],
            ignoreDefaultArgs: ['--enable-automation'],
            viewport: null,
          }
        );
        const page = context.pages()[0] || await context.newPage();

        // Your automation here:
        // await page.goto('https://example.com');
        // const text = await page.textContent('h1');
        // console.log(text);

        await context.close();
        ```

        Then run: `node /tmp/keyscribe-pw/task.mjs`

        ## Important rules
        - The browser has the user's REAL profile -- they are already logged in to their accounts
        - Prefer osascript for simple reads/navigations; use Playwright for complex flows
        - When using Playwright, always close the context when done (`await context.close()`)
        - When using Playwright, use `headless: false` so the user can see what is happening
        - When using Playwright, make sure the browser is not already open; if it is, ask the user to close it first
        - NEVER navigate to banking, financial, or sensitive account pages without explicit user instruction
        """
    }

    func browserTurnReminder() -> String? {
        Self.browserTurnReminder(from: browserProfileContext)
    }

    static func browserTurnReminder(from context: [String: String]?) -> String? {
        guard let ctx = context,
              let browser = ctx["browser"],
              let channel = ctx["channel"],
              let profileDir = ctx["profileDir"],
              let userDataDir = ctx["userDataDir"] else {
            return nil
        }

        let profilePath = "\(userDataDir)/\(profileDir)"
        let escapedProfilePath = profilePath.replacingOccurrences(of: "'", with: "\\'")
        let appName = channel == "brave" ? "Brave Browser" : "Google Chrome"
        let launchOptions: String
        if channel == "brave" {
            launchOptions = "executablePath: '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser'"
        } else {
            launchOptions = "channel: '\(channel)'"
        }

        return """
        # Browser Task Override

        If you use a browser in this turn, you MUST use the user's configured browser profile.
        - Browser: \(browser)
        - Profile: \(ctx["profileName"] ?? "Default")
        - Profile path: \(profilePath)

        Do NOT use MCP browser tools like `browser_navigate`, `browser_click`, `browser_snapshot`, `browser_run_code`, or any `playwright:*` tool. Those tools open a separate browser without the user's signed-in session.

        Use one of these instead:
        - Simple reads/navigation: `osascript` against "\(appName)"
        - Complex flows: Playwright `chromium.launchPersistentContext('\(escapedProfilePath)', { headless: false, \(launchOptions), args: ['--disable-blink-features=AutomationControlled', '--no-first-run', '--no-default-browser-check'], ignoreDefaultArgs: ['--enable-automation'], viewport: null })`

        If the browser is already open and you need Playwright, ask the user to close it first.
        """
    }

    private func threadResumeParams(threadID: String, cwd: String?, modelID: String?) -> [String: Any] {
        var params = threadStartParams(cwd: cwd, modelID: modelID)
        params["threadId"] = threadID
        return params
    }

    private func turnStartParams(
        threadID: String,
        prompt: String,
        attachments: [AssistantAttachment] = [],
        modelID: String?,
        resumeContext: String? = nil,
        memoryContext: String? = nil,
        browserContextOverride: String? = nil
    ) -> [String: Any] {
        var inputItems: [[String: Any]] = []
        // Add attachment items first so the model sees them before the prompt text
        for attachment in attachments {
            inputItems.append(attachment.toInputItem())
        }
        if let browserContextOverride = browserContextOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !browserContextOverride.isEmpty {
            inputItems.append(["type": "text", "text": browserContextOverride])
        }
        if let resumeContext = resumeContext?.trimmingCharacters(in: .whitespacesAndNewlines), !resumeContext.isEmpty {
            inputItems.append(["type": "text", "text": resumeContext])
        }
        if let memoryContext = memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines), !memoryContext.isEmpty {
            inputItems.append(["type": "text", "text": memoryContext])
        }
        if !prompt.isEmpty {
            inputItems.append(["type": "text", "text": prompt])
        }
        var params: [String: Any] = [
            "threadId": threadID,
            "input": inputItems,
            "approvalPolicy": "on-request"
        ]
        if let modelID = modelID?.nonEmpty {
            params["model"] = modelID
        }
        if let effort = reasoningEffort?.nonEmpty {
            params["effort"] = effort
        }

        // Build collaborationMode for the turn (only when a model is known).
        // The Codex protocol requires `model` as a non-optional field in settings,
        // so we skip collaborationMode entirely when no model has been selected.
        if let effectiveModel = (modelID?.nonEmpty ?? preferredModelID)?.nonEmpty {
            var modeSettings: [String: Any] = ["model": effectiveModel]
            if let effort = reasoningEffort?.nonEmpty {
                modeSettings["reasoningEffort"] = effort
            }
            params["collaborationMode"] = [
                "mode": interactionMode.codexModeKind,
                "settings": modeSettings
            ] as [String: Any]
        }

        return params
    }

    private func makeHealth(
        availability: AssistantRuntimeAvailability,
        summary: String,
        detail: String? = nil
    ) -> AssistantRuntimeHealth {
        AssistantRuntimeHealth(
            availability: availability,
            summary: summary,
            detail: detail,
            runtimePath: currentCodexPath,
            selectedModelID: preferredModelID,
            accountEmail: currentAccountSnapshot.email,
            accountPlan: currentAccountSnapshot.planType
        )
    }

    private func updateHUD(phase: AssistantHUDPhase, title: String, detail: String?) {
        let state = AssistantHUDState(phase: phase, title: title, detail: detail)
        let now = CFAbsoluteTimeGetCurrent()

        // Always emit immediately for phase changes; throttle detail-only updates to ~10Hz
        let isPhaseChange = phase != lastHUDPhase
        if isPhaseChange || now - lastHUDEmitTime >= 0.10 {
            hudThrottleItem?.cancel()
            hudThrottleItem = nil
            pendingHUDState = nil
            onHUDUpdate?(state)
            lastHUDEmitTime = now
            lastHUDPhase = phase
        } else {
            pendingHUDState = state
            if hudThrottleItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self, let pending = self.pendingHUDState else { return }
                    self.onHUDUpdate?(pending)
                    self.lastHUDEmitTime = CFAbsoluteTimeGetCurrent()
                    self.pendingHUDState = nil
                    self.hudThrottleItem = nil
                }
                hudThrottleItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: item)
            }
        }
    }

    private func compactDetail(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// Produces a short, human-readable summary of a raw shell command for the HUD.
    private func friendlyCommandSummary(_ raw: String) -> String {
        var cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common shell wrappers:  /bin/zsh -lc '...'  /bin/bash -c '...'
        let shellPattern = #"^(/\S+/)?(bash|zsh|sh)\s+(-\S+\s+)*['\"]?"#
        if let range = cmd.range(of: shellPattern, options: .regularExpression) {
            cmd = String(cmd[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip trailing quotes / heredoc markers
        if cmd.hasSuffix("'") || cmd.hasSuffix("\"") {
            cmd = String(cmd.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let heredoc = cmd.range(of: #"<<\s*'?EOF'?"#, options: .regularExpression) {
            cmd = String(cmd[..<heredoc.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract the first meaningful token (the actual command)
        let firstLine = cmd.components(separatedBy: .newlines).first ?? cmd
        let tokens = firstLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let base = tokens.first ?? cmd

        // Map well-known commands to friendly labels
        let labels: [String: String] = [
            "npm": "Running npm",
            "npx": "Running npx",
            "yarn": "Running yarn",
            "pnpm": "Running pnpm",
            "bun": "Running bun",
            "node": "Running Node.js",
            "python": "Running Python",
            "python3": "Running Python",
            "pip": "Installing packages",
            "pip3": "Installing packages",
            "swift": "Running Swift",
            "swiftc": "Compiling Swift",
            "xcodebuild": "Building with Xcode",
            "xcrun": "Running Xcode tool",
            "git": "Running git",
            "cargo": "Running Cargo",
            "rustc": "Compiling Rust",
            "go": "Running Go",
            "make": "Running make",
            "cmake": "Running CMake",
            "docker": "Running Docker",
            "kubectl": "Running kubectl",
            "curl": "Fetching URL",
            "wget": "Fetching URL",
            "cat": "Reading file",
            "ls": "Listing files",
            "find": "Searching files",
            "grep": "Searching content",
            "rg": "Searching content",
            "sed": "Editing text",
            "awk": "Processing text",
            "mkdir": "Creating directory",
            "rm": "Removing files",
            "cp": "Copying files",
            "mv": "Moving files",
            "chmod": "Changing permissions",
            "brew": "Running Homebrew",
            "apt": "Installing packages",
            "apt-get": "Installing packages",
            "cd": "Changing directory",
            "echo": "Running shell command",
            "env": "Running command",
            "which": "Locating command",
            "ruby": "Running Ruby",
            "gem": "Running gem",
            "java": "Running Java",
            "javac": "Compiling Java",
            "gradle": "Running Gradle",
            "mvn": "Running Maven",
            "pytest": "Running tests",
            "jest": "Running tests",
            "vitest": "Running tests",
        ]

        // Check for a known command
        let baseName = (base as NSString).lastPathComponent
        if let label = labels[baseName] {
            // Append subcommand for multi-verb CLIs where it adds clarity
            let multiVerb: Set<String> = ["git", "npm", "npx", "yarn", "pnpm", "bun", "swift", "cargo", "go", "docker", "kubectl", "brew", "apt", "apt-get"]
            if multiVerb.contains(baseName), tokens.count > 1 {
                return "\(label) \(tokens[1])"
            }
            return label
        }

        // Fallback: show the base command name (without path)
        if baseName.count <= 24 {
            return "Running \(baseName)"
        }
        return "Running command"
    }

    private func approvalRequestID(from id: JSONRPCRequestID) -> Int {
        switch id {
        case .int(let value):
            return value
        case .string(let value):
            return abs(value.hashValue)
        }
    }

    private func firstNonEmptyString(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func extractString(_ raw: Any?) -> String? {
        if let text = raw as? String {
            return text.nonEmpty
        }
        if let dictionary = raw as? [String: Any] {
            for key in ["message", "text", "content", "output", "description"] {
                if let text = extractString(dictionary[key]) {
                    return text
                }
            }
        }
        if let array = raw as? [Any] {
            let merged = array.compactMap { extractString($0) }.joined(separator: "\n")
            return merged.nonEmpty
        }
        return nil
    }

    // MARK: - AI Title Generation

    /// Generate a concise session title using a separate ephemeral Codex thread.
    /// The thread's notifications are intercepted so they don't appear in the main UI.
    func generateTitle(userPrompt: String, assistantResponse: String) async -> String? {
        guard transport != nil else { return nil }

        let responseSnippet = String(assistantResponse.prefix(500))
        let titlePrompt = """
        Generate a short title (max 6 words) for a conversation that starts with:

        User: \(userPrompt.prefix(300))

        Assistant: \(responseSnippet)

        Reply with ONLY the title text, nothing else. No quotes, no punctuation at the end, no prefix.
        """

        do {
            // Start an ephemeral thread for title generation
            let threadResponse = try await sendRequest(
                method: "thread/start",
                params: [
                    "approvalPolicy": "auto-approve",
                    "sandbox": "locked-network",
                    "ephemeral": true,
                    "instructions": "You are a title generator. Reply with only a short title, nothing else."
                ]
            )

            guard let payload = threadResponse.raw as? [String: Any],
                  let thread = payload["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String else {
                return nil
            }

            titleGenThreadID = threadID
            titleGenBuffer = ""

            // Send the title-generation turn
            _ = try await sendRequest(
                method: "turn/start",
                params: [
                    "threadId": threadID,
                    "input": [["type": "text", "text": titlePrompt]],
                    "approvalPolicy": "auto-approve"
                ]
            )

            // Wait for the title-generation turn to complete (via notifications)
            let title = await withCheckedContinuation { continuation in
                titleGenContinuation = continuation
            }

            titleGenThreadID = nil
            titleGenContinuation = nil

            let cleaned = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return cleaned.isEmpty ? nil : cleaned
        } catch {
            titleGenThreadID = nil
            titleGenContinuation = nil
            CrashReporter.logWarning("Title generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func handleTitleGenNotification(method: String, params: [String: Any]) {
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                let channel = (params["channel"] as? String)?.lowercased()
                if channel != "commentary" {
                    titleGenBuffer += delta
                }
            }
        case "turn/completed":
            titleGenContinuation?.resume(returning: titleGenBuffer)
        case "error":
            let message = firstNonEmptyString(
                params["message"] as? String,
                extractString(params["error"])
            ) ?? ""
            CrashReporter.logWarning("Title generation thread error: \(message)")
            titleGenContinuation?.resume(returning: "")
        default:
            break
        }
    }
}

private actor CodexAppServerTransport {
    private let incoming: @Sendable (CodexIncomingEvent) -> Void
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextClientRequestID = 1
    private var responseContinuations: [JSONRPCRequestID: CheckedContinuation<CodexResponsePayload, Error>] = [:]
    private var bufferedResponses: [JSONRPCRequestID: Result<CodexResponsePayload, Error>] = [:]

    init(incoming: @escaping @Sendable (CodexIncomingEvent) -> Void) {
        self.incoming = incoming
    }

    func isRunning() -> Bool {
        process?.isRunning ?? false
    }

    func start(codexExecutablePath: String) async throws {
        if process != nil {
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: codexExecutablePath)
        process.arguments = ["app-server"]
        process.environment = AssistantCommandEnvironment.mergedEnvironment()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [incoming] process in
            let message: String?
            if process.terminationReason == .uncaughtSignal {
                message = "Codex App Server exited because of a signal."
            } else if process.terminationStatus != 0 {
                message = "Codex App Server exited with code \(process.terminationStatus)."
            } else {
                message = nil
            }
            incoming(.processExited(message))
        }

        do {
            try process.run()
        } catch {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Could not launch Codex App Server: \(error.localizedDescription)")
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        configureReadabilityHandlers()

        _ = try await sendRequest(
            id: 0,
            method: "initialize",
            params: [
                "protocolVersion": 2,
                "clientInfo": [
                    "name": "KeyScribe",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        )
        try await sendNotification(method: "initialized", params: nil)
        nextClientRequestID = 1
    }

    func stop() async {
        let continuations = responseContinuations
        responseContinuations.removeAll()
        bufferedResponses.removeAll()
        for (_, continuation) in continuations {
            continuation.resume(throwing: CodexAssistantRuntimeError.runtimeUnavailable("Codex App Server closed."))
        }
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
        stdinHandle?.closeFile()
        stdinHandle = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    func sendRequest(method: String, params: [String: Any]) async throws -> CodexResponsePayload {
        let requestID = nextClientRequestID
        nextClientRequestID += 1
        return try await sendRequest(id: requestID, method: method, params: params)
    }

    func sendResponse(id: JSONRPCRequestID, result: [String: Any]) async throws {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.rawValue,
            "result": result
        ]
        let encoded = try JSONSerialization.data(withJSONObject: message, options: [])
        try write(data: encoded + Data("\n".utf8))
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]) async throws -> CodexResponsePayload {
        let requestID = JSONRPCRequestID.int(id)
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let encoded = try JSONSerialization.data(withJSONObject: message, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            if let buffered = bufferedResponses.removeValue(forKey: requestID) {
                continuation.resume(with: buffered)
                return
            }

            responseContinuations[requestID] = continuation
            do {
                try write(data: encoded + Data("\n".utf8))
            } catch {
                responseContinuations.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]?) async throws {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            message["params"] = params
        }
        let encoded = try JSONSerialization.data(withJSONObject: message, options: [])
        try write(data: encoded + Data("\n".utf8))
    }

    private func configureReadabilityHandlers() {
        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consumeIncomingData(data, isErrorStream: false)
            }
        }

        stderrHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consumeIncomingData(data, isErrorStream: true)
            }
        }
    }

    private func consumeIncomingData(_ data: Data, isErrorStream: Bool) async {
        if data.isEmpty {
            if isErrorStream {
                stderrHandle?.readabilityHandler = nil
            } else {
                stdoutHandle?.readabilityHandler = nil
            }
            return
        }

        if isErrorStream {
            stderrBuffer.append(data)
            await flushBufferedLines(isErrorStream: true)
        } else {
            stdoutBuffer.append(data)
            await flushBufferedLines(isErrorStream: false)
        }
    }

    private func flushBufferedLines(isErrorStream: Bool) async {
        let newline = UInt8(ascii: "\n")

        while true {
            let range: Range<Data.Index>?
            if isErrorStream {
                range = stderrBuffer.firstRange(of: Data([newline]))
            } else {
                range = stdoutBuffer.firstRange(of: Data([newline]))
            }

            guard let range else { break }

            let lineData: Data
            if isErrorStream {
                lineData = stderrBuffer.subdata(in: stderrBuffer.startIndex..<range.lowerBound)
                stderrBuffer.removeSubrange(stderrBuffer.startIndex...range.lowerBound)
            } else {
                lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)
            }

            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if isErrorStream {
                let lower = line.lowercased()
                let isNoisy = lower.contains("failed to load rollout")
                    || lower.contains("failed to parse thread id")
                    || lower.contains("deprecation")
                if !isNoisy {
                    incoming(.statusMessage(line))
                }
            } else {
                await handleOutputLine(line)
            }
        }
    }

    private func handleOutputLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            CrashReporter.logWarning("Assistant runtime received non-JSON output from Codex App Server")
            incoming(.statusMessage("Received non-JSON output from Codex App Server."))
            return
        }

            if json["method"] == nil, let responseID = parseRequestID(json["id"]) {
            let result: Result<CodexResponsePayload, Error>
            if let errorObject = json["error"] as? [String: Any] {
                result = .failure(
                    CodexAssistantRuntimeError.requestFailed(
                        errorObject["message"] as? String ?? "Codex App Server request failed."
                    )
                )
            } else {
                result = .success(CodexResponsePayload(raw: json["result"] as Any))
            }

            if let continuation = responseContinuations.removeValue(forKey: responseID) {
                continuation.resume(with: result)
            } else {
                bufferedResponses[responseID] = result
            }
            return
        }

        guard let method = json["method"] as? String,
              let params = json["params"] as? [String: Any] else {
            return
        }

        if let requestID = parseRequestID(json["id"]) {
            incoming(.serverRequest(id: requestID, method: method, params: params))
        } else {
            incoming(.notification(method: method, params: params))
        }
    }

    private func parseRequestID(_ raw: Any?) -> JSONRPCRequestID? {
        if let value = raw as? Int {
            return .int(value)
        }
        if let value = raw as? String {
            return .string(value)
        }
        return nil
    }

    private func write(data: Data) throws {
        guard let stdinHandle else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Codex App Server is not running.")
        }
        try stdinHandle.write(contentsOf: data)
    }
}

@MainActor
private final class PendingPermissionContext {
    let request: AssistantPermissionRequest
    private let selectHandler: @Sendable (String) async -> Void
    private let cancelHandler: @Sendable () async -> Void

    init(
        request: AssistantPermissionRequest,
        selectHandler: @escaping @Sendable (String) async -> Void,
        cancelHandler: @escaping @Sendable () async -> Void
    ) {
        self.request = request
        self.selectHandler = selectHandler
        self.cancelHandler = cancelHandler
    }

    func select(optionID: String) async {
        await selectHandler(optionID)
    }

    func cancel() async {
        await cancelHandler()
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var merged = lhs
        merged.append(rhs)
        return merged
    }
}
