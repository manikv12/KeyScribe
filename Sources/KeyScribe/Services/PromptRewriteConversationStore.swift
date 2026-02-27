import AppKit
import CryptoKit
import Foundation

struct PromptRewriteConversationTurn: Codable, Equatable {
    let userText: String
    let assistantText: String
    let timestamp: Date
    let isSummary: Bool
    let sourceTurnCount: Int?
    let compactionVersion: Int?

    init(
        userText: String,
        assistantText: String,
        timestamp: Date = Date(),
        isSummary: Bool = false,
        sourceTurnCount: Int? = nil,
        compactionVersion: Int? = nil
    ) {
        self.userText = userText
        self.assistantText = assistantText
        self.timestamp = timestamp
        self.isSummary = isSummary
        self.sourceTurnCount = sourceTurnCount
        self.compactionVersion = compactionVersion
    }

    private enum CodingKeys: String, CodingKey {
        case userText
        case assistantText
        case timestamp
        case isSummary
        case sourceTurnCount
        case compactionVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userText = try container.decodeIfPresent(String.self, forKey: .userText) ?? ""
        assistantText = try container.decodeIfPresent(String.self, forKey: .assistantText) ?? ""
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        isSummary = try container.decodeIfPresent(Bool.self, forKey: .isSummary) ?? false
        sourceTurnCount = try container.decodeIfPresent(Int.self, forKey: .sourceTurnCount)
        compactionVersion = try container.decodeIfPresent(Int.self, forKey: .compactionVersion)
    }
}

struct PromptRewriteConversationContext: Codable, Equatable, Identifiable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let screenLabel: String
    let fieldLabel: String
    let logicalSurfaceKey: String
    let projectKey: String?
    let projectLabel: String?
    let identityKey: String?
    let identityType: String?
    let identityLabel: String?
    let nativeThreadKey: String?
    let people: [String]

    init(
        id: String,
        appName: String,
        bundleIdentifier: String,
        screenLabel: String,
        fieldLabel: String,
        logicalSurfaceKey: String = "",
        projectKey: String? = nil,
        projectLabel: String? = nil,
        identityKey: String? = nil,
        identityType: String? = nil,
        identityLabel: String? = nil,
        nativeThreadKey: String? = nil,
        people: [String] = []
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.screenLabel = screenLabel
        self.fieldLabel = fieldLabel
        self.logicalSurfaceKey = logicalSurfaceKey
        self.projectKey = projectKey
        self.projectLabel = projectLabel
        self.identityKey = identityKey
        self.identityType = identityType
        self.identityLabel = identityLabel
        self.nativeThreadKey = nativeThreadKey
        self.people = people
    }

    var displayName: String {
        let normalizedProject = projectLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedIdentity = identityLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedScreen = screenLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedField = fieldLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments: [String] = [appName]
        if !normalizedProject.isEmpty {
            segments.append(normalizedProject)
        }
        if !normalizedIdentity.isEmpty {
            segments.append(normalizedIdentity)
        }
        if !normalizedScreen.isEmpty {
            segments.append(normalizedScreen)
        }
        if !normalizedField.isEmpty {
            segments.append(normalizedField)
        }
        return segments.joined(separator: " - ")
    }

    var providerContextLabel: String {
        let normalizedProject = projectLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedIdentity = identityLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedScreen = screenLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedField = fieldLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments: [String] = [appName]
        if Self.isMeaningfulProjectLabel(normalizedProject) {
            segments.append("project: \(normalizedProject)")
        }
        if Self.isMeaningfulIdentityLabel(normalizedIdentity) {
            segments.append("identity: \(normalizedIdentity)")
        }
        if Self.isMeaningfulScreenLabel(normalizedScreen) {
            segments.append("screen: \(normalizedScreen)")
        }
        if Self.isMeaningfulFieldLabel(normalizedField) {
            segments.append("field: \(normalizedField)")
        }
        return segments.joined(separator: ", ")
    }

    private static func isMeaningfulProjectLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        if lowered == "unknown project" || lowered == "current screen" || lowered == "focused input" {
            return false
        }
        if normalized.count > 96 {
            return false
        }
        return true
    }

    private static func isMeaningfulIdentityLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        if lowered == "unknown identity" || lowered == "unknown channel" || lowered == "unknown chat" {
            return false
        }
        return true
    }

    private static func isMeaningfulScreenLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        if lowered == "current screen" {
            return false
        }
        return true
    }

    private static func isMeaningfulFieldLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        let genericFields: Set<String> = [
            "focused input",
            "type a message",
            "message",
            "input"
        ]
        return !genericFields.contains(lowered)
    }
}

struct PromptRewriteConversationContextSummary: Identifiable, Equatable {
    let id: String
    let displayName: String
    let appName: String
    let screenLabel: String
    let fieldLabel: String
    let projectLabel: String?
    let identityLabel: String?
    let lastUpdatedAt: Date
    let turnCount: Int
}

struct PromptRewriteConversationContextDetail: Identifiable, Equatable {
    let context: PromptRewriteConversationContext
    let turns: [PromptRewriteConversationTurn]
    let lastUpdatedAt: Date

    var id: String { context.id }

    var totalTurnCount: Int {
        turns.count
    }

    var summaryTurnCount: Int {
        turns.filter(\.isSummary).count
    }

    var exchangeTurnCount: Int {
        turns.filter { !$0.isSummary }.count
    }

    var estimatedCharacterCount: Int {
        turns.reduce(into: 0) { partial, turn in
            partial += turn.userText.count
            partial += turn.assistantText.count
        }
    }

    var estimatedTokenCount: Int {
        max(0, Int((Double(estimatedCharacterCount) / 4).rounded()))
    }
}

struct PromptRewriteConversationCompactionReport: Equatable {
    let contextID: String
    let previousTurnCount: Int
    let compactedTurnCount: Int
    let newTurnCount: Int
}

@MainActor
final class PromptRewriteConversationStore: ObservableObject {
    static let shared = PromptRewriteConversationStore()

    struct RequestContext {
        let context: PromptRewriteConversationContext
        let history: [PromptRewriteConversationTurn]
        let usesPinnedContext: Bool
    }

    private struct StoredContext {
        var context: PromptRewriteConversationContext
        var turns: [PromptRewriteConversationTurn]
        var lastUpdatedAt: Date
        var tupleKey: ConversationThreadTupleKey
        var totalExchangeTurns: Int
    }

    @Published private(set) var contextSummaries: [PromptRewriteConversationContextSummary] = []

    private let maxStoredContexts = 24
    private let maxStoredTurnsPerContext = 120
    private let maxRelevantExchangeTurnsForPrompt = 6
    private let autoCompactionExchangeThreshold = 40
    private let autoCompactionRetainedExchangeTurns = 8
    private let maxPromptContextCharacters = 2_500
    private let compactionVersion = 1
    private let sqliteStoreFactory: () throws -> MemorySQLiteStore
    private let tagInferenceService: ConversationTagInferenceService

    private var contextsByID: [String: StoredContext] = [:]
    private var contextIDByTuple: [ConversationThreadTupleKey: String] = [:]
    private var sqliteStore: MemorySQLiteStore?

    private init(
        sqliteStoreFactory: @escaping () throws -> MemorySQLiteStore = { try MemorySQLiteStore() },
        tagInferenceService: ConversationTagInferenceService = .shared
    ) {
        self.sqliteStoreFactory = sqliteStoreFactory
        self.tagInferenceService = tagInferenceService
        loadFromSQLite()
        refreshSummaries()
    }

    func prepareRequestContext(
        capturedContext: PromptRewriteConversationContext,
        userText: String = "",
        timeoutMinutes: Double,
        turnLimit: Int,
        pinnedContextID: String?
    ) -> RequestContext {
        pruneStaleContexts(timeoutMinutes: timeoutMinutes)

        let normalizedPinnedID = pinnedContextID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedContext: StoredContext?
        if let normalizedPinnedID, !normalizedPinnedID.isEmpty {
            pinnedContext = contextsByID[normalizedPinnedID]
        } else {
            pinnedContext = nil
        }

        let resolvedContext: PromptRewriteConversationContext
        let usesPinnedContext: Bool
        let history: [PromptRewriteConversationTurn]
        let resolutionSource: String
        let resolvedTupleKey: ConversationThreadTupleKey
        if let pinnedContext {
            resolvedContext = pinnedContext.context
            usesPinnedContext = true
            history = promptHistory(for: resolvedContext.id, limit: normalizedTurnLimit(turnLimit), userText: userText)
            resolutionSource = "pinned"
            resolvedTupleKey = pinnedContext.tupleKey
        } else {
            let inferred = canonicalizedTags(
                tagInferenceService.inferTags(
                    capturedContext: capturedContext,
                    userText: ""
                )
            )
            let tupleKey = tagInferenceService.tupleKey(
                capturedContext: capturedContext,
                tags: inferred
            )
            if let existingID = contextIDByTuple[tupleKey],
               var existing = contextsByID[existingID] {
                let refreshedContext = tupleContext(
                    baseContext: capturedContext,
                    tupleKey: tupleKey,
                    tags: inferred,
                    threadID: existing.context.id
                )
                existing.context = refreshedContext
                existing.tupleKey = tupleKey
                contextsByID[existingID] = existing
                resolvedContext = refreshedContext
                history = promptHistory(
                    for: resolvedContext.id,
                    limit: normalizedTurnLimit(turnLimit),
                    userText: userText
                )
                resolutionSource = "in-memory"
                resolvedTupleKey = tupleKey
            } else if let store = resolvedSQLiteStore(),
                      let thread = try? store.fetchConversationThread(
                          bundleID: tupleKey.bundleID,
                          logicalSurfaceKey: tupleKey.logicalSurfaceKey,
                          projectKey: tupleKey.projectKey,
                          identityKey: tupleKey.identityKey,
                          nativeThreadKey: tupleKey.nativeThreadKey
                      ) {
                let resolvedLoadedContext = tupleContext(
                    baseContext: capturedContext,
                    tupleKey: tupleKey,
                    tags: inferred,
                    threadID: thread.id
                )
                let loadedTurns = ((try? store.fetchConversationTurns(threadID: thread.id, limit: 300)) ?? [])
                    .compactMap(conversationTurn(from:))
                let loaded = StoredContext(
                    context: resolvedLoadedContext,
                    turns: loadedTurns,
                    lastUpdatedAt: thread.lastActivityAt,
                    tupleKey: tupleKey,
                    totalExchangeTurns: max(thread.totalExchangeTurns, loadedTurns.filter { !$0.isSummary }.count)
                )
                contextsByID[thread.id] = loaded
                contextIDByTuple[tupleKey] = thread.id
                resolvedContext = resolvedLoadedContext
                history = promptHistory(
                    for: resolvedContext.id,
                    limit: normalizedTurnLimit(turnLimit),
                    userText: userText
                )
                resolutionSource = "sqlite"
                resolvedTupleKey = tupleKey
            } else {
                let threadID = tagInferenceService.threadID(for: tupleKey)
                resolvedContext = tupleContext(
                    baseContext: capturedContext,
                    tupleKey: tupleKey,
                    tags: inferred,
                    threadID: threadID
                )
                history = []
                resolutionSource = "new"
                resolvedTupleKey = tupleKey
            }
            usesPinnedContext = false
        }

        CrashReporter.logInfo(
            """
            Prompt rewrite context resolved \
            source=\(resolutionSource) \
            contextID=\(resolvedContext.id) \
            app=\(resolvedContext.appName) \
            bundle=\(resolvedTupleKey.bundleID) \
            project=\(resolvedTupleKey.projectKey) \
            identity=\(resolvedTupleKey.identityKey) \
            historyTurns=\(history.count)
            """
        )

        return RequestContext(
            context: resolvedContext,
            history: history,
            usesPinnedContext: usesPinnedContext
        )
    }

    func recordTurn(
        originalText: String,
        finalText: String,
        context: PromptRewriteConversationContext,
        timeoutMinutes: Double,
        maxTurns: Int
    ) {
        let normalizedOriginal = collapsedWhitespace(originalText)
        let normalizedFinal = sanitizedAssistantTurnText(
            finalText,
            originalUserText: normalizedOriginal
        )
        guard !normalizedOriginal.isEmpty, !normalizedFinal.isEmpty else {
            return
        }

        pruneStaleContexts(timeoutMinutes: timeoutMinutes)

        let now = Date()
        let inferredTags = resolvedTags(
            from: context,
            originalText: normalizedOriginal,
            finalText: normalizedFinal
        )
        let tupleKey = tagInferenceService.tupleKey(
            capturedContext: context,
            tags: inferredTags
        )
        let threadID = tagInferenceService.threadID(for: tupleKey)
        let resolvedContext = tupleContext(
            baseContext: context,
            tupleKey: tupleKey,
            tags: inferredTags,
            threadID: threadID
        )

        var stored = contextsByID[threadID] ?? StoredContext(
            context: resolvedContext,
            turns: [],
            lastUpdatedAt: now,
            tupleKey: tupleKey,
            totalExchangeTurns: 0
        )

        stored.context = resolvedContext
        stored.tupleKey = tupleKey
        stored.lastUpdatedAt = now
        let userSnippet = snippet(normalizedOriginal, limit: 420)
        let assistantSnippet = snippet(normalizedFinal, limit: 420)
        if let last = stored.turns.last,
           !last.isSummary,
           last.userText == userSnippet,
           last.assistantText == assistantSnippet {
            return
        }

        stored.turns.append(
            PromptRewriteConversationTurn(
                userText: userSnippet,
                assistantText: assistantSnippet,
                timestamp: now
            )
        )
        stored.totalExchangeTurns += 1

        let keepRecentTurns = normalizedTurnLimit(maxTurns)
        autoCompactContextIfNeeded(&stored)
        enforceHardTurnCap(&stored, keepRecentTurns: keepRecentTurns)

        contextsByID[threadID] = stored
        contextIDByTuple[tupleKey] = threadID
        let removedContextIDs = trimStoredContextsIfNeeded()
        persistContext(stored)
        for removedID in removedContextIDs {
            deleteContextFromSQLite(id: removedID)
        }
        refreshSummaries()
    }

    func clearContext(id: String) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        guard let removed = contextsByID.removeValue(forKey: normalizedID) else { return }
        contextIDByTuple.removeValue(forKey: removed.tupleKey)
        deleteContextFromSQLite(id: normalizedID)
        refreshSummaries()
    }

    func clearAll() {
        guard !contextsByID.isEmpty else { return }
        contextsByID.removeAll()
        contextIDByTuple.removeAll()
        clearAllContextsInSQLite()
        refreshSummaries()
    }

    func hasContext(id: String) -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return false }
        return contextsByID[normalizedID] != nil
    }

    func contextDetails(timeoutMinutes: Double? = nil) -> [PromptRewriteConversationContextDetail] {
        if let timeoutMinutes {
            pruneStaleContexts(timeoutMinutes: timeoutMinutes)
        }

        return contextsByID
            .values
            .sorted { lhs, rhs in
                lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            .map { stored in
                PromptRewriteConversationContextDetail(
                    context: stored.context,
                    turns: stored.turns,
                    lastUpdatedAt: stored.lastUpdatedAt
                )
            }
    }

    func contextDetail(id: String, timeoutMinutes: Double? = nil) -> PromptRewriteConversationContextDetail? {
        if let timeoutMinutes {
            pruneStaleContexts(timeoutMinutes: timeoutMinutes)
        }

        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              let stored = contextsByID[normalizedID] else {
            return nil
        }

        return PromptRewriteConversationContextDetail(
            context: stored.context,
            turns: stored.turns,
            lastUpdatedAt: stored.lastUpdatedAt
        )
    }

    func serializedContextJSON(id: String) -> String? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              let stored = contextsByID[normalizedID] else {
            return nil
        }

        struct SerializedContextPayload: Codable {
            let context: PromptRewriteConversationContext
            let turns: [PromptRewriteConversationTurn]
            let lastUpdatedAt: Date
            let totalExchangeTurns: Int
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = SerializedContextPayload(
            context: stored.context,
            turns: stored.turns,
            lastUpdatedAt: stored.lastUpdatedAt,
            totalExchangeTurns: stored.totalExchangeTurns
        )
        guard let data = try? encoder.encode(payload),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    func compactContext(id: String, keepRecentTurns: Int) -> PromptRewriteConversationCompactionReport? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              var stored = contextsByID[normalizedID] else {
            return nil
        }

        guard let report = compactStoredContext(
            &stored,
            keepRecentTurns: keepRecentTurns,
            force: true,
            trigger: .manualCompaction
        ) else {
            return nil
        }

        contextsByID[normalizedID] = stored
        persistContext(stored)
        refreshSummaries()
        return report
    }

    func compactAllContexts(keepRecentTurns: Int) -> [PromptRewriteConversationCompactionReport] {
        var reports: [PromptRewriteConversationCompactionReport] = []
        let normalizedKeepRecentTurns = normalizedTurnLimit(keepRecentTurns)

        for contextID in contextsByID.keys.sorted() {
            guard var stored = contextsByID[contextID] else { continue }
            guard let report = compactStoredContext(
                &stored,
                keepRecentTurns: normalizedKeepRecentTurns,
                force: true,
                trigger: .manualCompaction
            ) else {
                continue
            }
            contextsByID[contextID] = stored
            reports.append(report)
        }

        guard !reports.isEmpty else { return [] }
        for report in reports {
            if let stored = contextsByID[report.contextID] {
                persistContext(stored)
            }
        }
        refreshSummaries()
        return reports
    }

    private func tupleContext(
        baseContext: PromptRewriteConversationContext,
        tupleKey: ConversationThreadTupleKey,
        tags: ConversationTupleTags,
        threadID: String
    ) -> PromptRewriteConversationContext {
        PromptRewriteConversationContext(
            id: threadID,
            appName: baseContext.appName,
            bundleIdentifier: baseContext.bundleIdentifier,
            screenLabel: baseContext.screenLabel,
            fieldLabel: baseContext.fieldLabel,
            logicalSurfaceKey: tupleKey.logicalSurfaceKey,
            projectKey: tags.projectKey,
            projectLabel: tags.projectLabel,
            identityKey: tags.identityKey,
            identityType: tags.identityType,
            identityLabel: tags.identityLabel,
            nativeThreadKey: tags.nativeThreadKey,
            people: tags.people
        )
    }

    private func canonicalizedTags(_ tags: ConversationTupleTags) -> ConversationTupleTags {
        guard let store = resolvedSQLiteStore() else {
            return tags
        }
        let normalizedProjectKey = tags.projectKey.lowercased()
        let normalizedIdentityKey = tags.identityKey.lowercased()
        var canonicalProject = normalizedProjectKey
        if let resolved = try? store.resolveConversationTagAlias(aliasType: "project", aliasKey: normalizedProjectKey),
           !resolved.isEmpty {
            canonicalProject = resolved
        }
        var canonicalIdentity = normalizedIdentityKey
        if let resolved = try? store.resolveConversationTagAlias(aliasType: "identity", aliasKey: normalizedIdentityKey),
           !resolved.isEmpty {
            canonicalIdentity = resolved
        }
        if canonicalProject != normalizedProjectKey {
            try? store.upsertConversationTagAlias(
                aliasType: "project",
                aliasKey: normalizedProjectKey,
                canonicalKey: canonicalProject
            )
        }
        if canonicalIdentity != normalizedIdentityKey {
            try? store.upsertConversationTagAlias(
                aliasType: "identity",
                aliasKey: normalizedIdentityKey,
                canonicalKey: canonicalIdentity
            )
        }
        return ConversationTupleTags(
            projectKey: canonicalProject,
            projectLabel: tags.projectLabel,
            identityKey: canonicalIdentity,
            identityType: tags.identityType,
            identityLabel: tags.identityLabel,
            people: tags.people,
            nativeThreadKey: tags.nativeThreadKey
        )
    }

    private func resolvedTags(
        from context: PromptRewriteConversationContext,
        originalText: String,
        finalText: String
    ) -> ConversationTupleTags {
        if let projectKey = context.projectKey,
           let projectLabel = context.projectLabel,
           let identityKey = context.identityKey,
           let identityType = context.identityType,
           let identityLabel = context.identityLabel {
            return canonicalizedTags(
                ConversationTupleTags(
                    projectKey: projectKey,
                    projectLabel: projectLabel,
                    identityKey: identityKey,
                    identityType: identityType,
                    identityLabel: identityLabel,
                    people: context.people,
                    nativeThreadKey: context.nativeThreadKey ?? ""
                )
            )
        }

        return canonicalizedTags(
            tagInferenceService.inferTags(
                capturedContext: context,
                userText: ""
            )
        )
    }

    private func promptHistory(
        for contextID: String,
        limit: Int,
        userText: String
    ) -> [PromptRewriteConversationTurn] {
        guard let stored = contextsByID[contextID] else { return [] }
        return selectedTurnsForPrompt(
            from: stored.turns,
            limit: limit,
            userText: userText
        )
    }

    private func selectedTurnsForPrompt(
        from turns: [PromptRewriteConversationTurn],
        limit: Int,
        userText: String
    ) -> [PromptRewriteConversationTurn] {
        let normalizedLimit = min(
            normalizedTurnLimit(limit),
            maxRelevantExchangeTurnsForPrompt + 1
        )
        guard turns.count > normalizedLimit else { return turns }

        if normalizedLimit <= 1 {
            return Array(turns.filter { !$0.isSummary }.suffix(1))
        }

        let latestSummary = turns.reversed().first(where: \.isSummary)
        let nonSummaryBudget = max(1, normalizedLimit - (latestSummary == nil ? 0 : 1))
        let nonSummaryTurns = turns.filter { !$0.isSummary }
        let queryTokens = Set(
            MemoryTextNormalizer.keywords(
                from: collapsedWhitespace(userText).lowercased(),
                limit: 16
            )
        )

        let ranked = nonSummaryTurns.enumerated().map { index, turn -> (turn: PromptRewriteConversationTurn, score: Double) in
            let recencyScore = Double(index + 1) / Double(max(1, nonSummaryTurns.count))
            let turnTokens = Set(
                MemoryTextNormalizer.keywords(
                    from: "\(turn.userText) \(turn.assistantText)".lowercased(),
                    limit: 24
                )
            )
            let overlapScore: Double
            if queryTokens.isEmpty {
                overlapScore = 0
            } else {
                let shared = queryTokens.intersection(turnTokens).count
                overlapScore = Double(shared) / Double(max(1, queryTokens.count))
            }
            return (turn: turn, score: (overlapScore * 0.65) + (recencyScore * 0.35))
        }

        let selectedNonSummary = ranked
            .sorted {
                if $0.score == $1.score {
                    return $0.turn.timestamp < $1.turn.timestamp
                }
                return $0.score > $1.score
            }
            .prefix(nonSummaryBudget)
            .map(\.turn)
            .sorted { lhs, rhs in
                lhs.timestamp < rhs.timestamp
            }

        var output: [PromptRewriteConversationTurn] = []
        if let latestSummary {
            output.append(latestSummary)
        }
        output.append(contentsOf: selectedNonSummary)

        if output.count > normalizedLimit {
            output = Array(output.suffix(normalizedLimit))
        }

        while estimatedContextCharacters(output) > maxPromptContextCharacters,
              output.count > 1 {
            if let index = output.firstIndex(where: { !$0.isSummary }) {
                output.remove(at: index)
            } else {
                break
            }
        }

        return output
    }

    private func autoCompactContextIfNeeded(_ stored: inout StoredContext) {
        let exchangeTurns = stored.turns.filter { !$0.isSummary }.count
        guard exchangeTurns > autoCompactionExchangeThreshold else { return }
        _ = compactStoredContext(
            &stored,
            keepRecentTurns: autoCompactionRetainedExchangeTurns,
            force: false,
            trigger: .autoCompaction
        )
    }

    private func enforceHardTurnCap(_ stored: inout StoredContext, keepRecentTurns: Int) {
        guard stored.turns.count > maxStoredTurnsPerContext else { return }
        if compactStoredContext(
            &stored,
            keepRecentTurns: max(2, keepRecentTurns),
            force: true,
            trigger: .autoCompaction
        ) != nil,
           stored.turns.count <= maxStoredTurnsPerContext {
            return
        }

        let overflow = max(0, stored.turns.count - maxStoredTurnsPerContext)
        guard overflow > 0 else { return }
        stored.turns = Array(stored.turns.dropFirst(overflow))
    }

    private func compactStoredContext(
        _ stored: inout StoredContext,
        keepRecentTurns: Int,
        force: Bool,
        trigger: MemoryPromotionTrigger = .autoCompaction
    ) -> PromptRewriteConversationCompactionReport? {
        let normalizedKeepRecentTurns = normalizedTurnLimit(keepRecentTurns)
        let previousTurnCount = stored.turns.count
        guard previousTurnCount > normalizedKeepRecentTurns else { return nil }

        let turnIndexesToKeep = recentExchangeTurnIndexes(
            in: stored.turns,
            keepRecentTurns: normalizedKeepRecentTurns
        )
        guard !turnIndexesToKeep.isEmpty else { return nil }

        let olderTurns = stored.turns.enumerated()
            .filter { !turnIndexesToKeep.contains($0.offset) }
            .map(\.element)
        var recentTurns = stored.turns.enumerated()
            .filter { turnIndexesToKeep.contains($0.offset) }
            .map(\.element)
        recentTurns = recentTurns.filter { !$0.isSummary }

        let olderExchangeCount = olderTurns.filter { !$0.isSummary }.count
        if !force && olderExchangeCount == 0 {
            return nil
        }

        guard !olderTurns.isEmpty else { return nil }
        let summaryText = compactionSummary(for: olderTurns, context: stored.context)
        guard !summaryText.isEmpty else { return nil }

        let compactedTurnCount = olderTurns.reduce(into: 0) { partial, turn in
            if turn.isSummary {
                partial += max(1, turn.sourceTurnCount ?? 1)
            } else {
                partial += 1
            }
        }

        let summaryTurn = PromptRewriteConversationTurn(
            userText: "Compacted conversation summary",
            assistantText: summaryText,
            timestamp: Date(),
            isSummary: true,
            sourceTurnCount: compactedTurnCount,
            compactionVersion: compactionVersion
        )
        stored.turns = [summaryTurn] + recentTurns
        stored.lastUpdatedAt = Date()
        stored.totalExchangeTurns = max(
            stored.totalExchangeTurns,
            compactedTurnCount + recentTurns.count
        )

        enqueueConversationPromotion(
            context: stored.context,
            summaryText: summaryText,
            sourceTurnCount: compactedTurnCount,
            compactionVersion: summaryTurn.compactionVersion,
            trigger: trigger,
            recentTurns: recentTurns,
            timestamp: summaryTurn.timestamp
        )

        return PromptRewriteConversationCompactionReport(
            contextID: stored.context.id,
            previousTurnCount: previousTurnCount,
            compactedTurnCount: compactedTurnCount,
            newTurnCount: stored.turns.count
        )
    }

    private func recentExchangeTurnIndexes(
        in turns: [PromptRewriteConversationTurn],
        keepRecentTurns: Int
    ) -> Set<Int> {
        var indexes: Set<Int> = []
        var remaining = max(1, keepRecentTurns)

        for index in stride(from: turns.count - 1, through: 0, by: -1) {
            let turn = turns[index]
            if turn.isSummary {
                continue
            }
            indexes.insert(index)
            remaining -= 1
            if remaining == 0 {
                break
            }
        }

        return indexes
    }

    private func compactionSummary(
        for olderTurns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext
    ) -> String {
        let priorSummarySnippets = olderTurns
            .filter(\.isSummary)
            .map(\.assistantText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let userSnippets = olderTurns
            .filter { !$0.isSummary }
            .map(\.userText)
        let assistantSnippets = olderTurns
            .filter { !$0.isSummary }
            .map(\.assistantText)

        let goalLines = distinctSnippets(from: userSnippets, limit: 3, snippetLimit: 180)
        let accomplishmentLines = distinctSnippets(from: assistantSnippets, limit: 4, snippetLimit: 200)
        let priorSummaryLines = distinctSnippets(from: priorSummarySnippets, limit: 2, snippetLimit: 220)

        var sections: [String] = []
        sections.append("## Context")
        sections.append("- \(context.providerContextLabel)")
        sections.append("")
        sections.append("## Goal")
        if goalLines.isEmpty {
            sections.append("- Continue the same user intent and style from prior turns.")
        } else {
            sections.append(contentsOf: goalLines.map { "- \($0)" })
        }
        sections.append("")
        sections.append("## Accomplished")
        if accomplishmentLines.isEmpty {
            sections.append("- Prior responses and revisions were exchanged in this context.")
        } else {
            sections.append(contentsOf: accomplishmentLines.map { "- \($0)" })
        }
        if !priorSummaryLines.isEmpty {
            sections.append("")
            sections.append("## Prior Summary Signals")
            sections.append(contentsOf: priorSummaryLines.map { "- \($0)" })
        }
        sections.append("")
        sections.append("## Handoff")
        sections.append("- Use this summary with the most recent turns to continue naturally.")
        sections.append("- Preserve the user's intent, tone, and any explicit constraints from this context.")

        return snippet(sections.joined(separator: "\n"), limit: 1_800)
    }

    private func distinctSnippets(
        from values: [String],
        limit: Int,
        snippetLimit: Int
    ) -> [String] {
        var output: [String] = []
        var seen: Set<String> = []

        for value in values {
            let normalized = collapsedWhitespace(value)
            guard !normalized.isEmpty else { continue }
            let concise = snippet(normalized, limit: snippetLimit)
            let key = concise.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(concise)
            if output.count >= limit {
                break
            }
        }

        return output
    }

    private func normalizedTurnLimit(_ value: Int) -> Int {
        min(50, max(1, value))
    }

    private func normalizedTimeoutMinutes(_ value: Double) -> Double {
        let fallback = 25.0
        guard value.isFinite else { return fallback }
        return min(240, max(2, value))
    }

    private func pruneStaleContexts(timeoutMinutes: Double) {
        guard !contextsByID.isEmpty else { return }

        let timeout = normalizedTimeoutMinutes(timeoutMinutes) * 60
        let now = Date()
        let staleIDs = contextsByID.compactMap { (id, stored) in
            now.timeIntervalSince(stored.lastUpdatedAt) > timeout ? id : nil
        }

        guard !staleIDs.isEmpty else { return }
        for id in staleIDs {
            if let stored = contextsByID[id], !stored.turns.isEmpty {
                let summaryText = compactionSummary(for: stored.turns, context: stored.context)
                if !summaryText.isEmpty {
                    let sourceTurnCount = stored.turns.reduce(into: 0) { partial, turn in
                        if turn.isSummary {
                            partial += max(1, turn.sourceTurnCount ?? 1)
                        } else {
                            partial += 1
                        }
                    }
                    enqueueConversationPromotion(
                        context: stored.context,
                        summaryText: summaryText,
                        sourceTurnCount: max(1, sourceTurnCount),
                        compactionVersion: compactionVersion,
                        trigger: .timeout,
                        recentTurns: Array(stored.turns.filter { !$0.isSummary }.suffix(autoCompactionRetainedExchangeTurns)),
                        timestamp: now
                    )
                }
                contextIDByTuple.removeValue(forKey: stored.tupleKey)
            }
            contextsByID.removeValue(forKey: id)
            deleteContextFromSQLite(id: id)
        }
        refreshSummaries()
    }

    private func trimStoredContextsIfNeeded() -> [String] {
        guard contextsByID.count > maxStoredContexts else { return [] }

        let sortedIDs = contextsByID
            .sorted { lhs, rhs in
                lhs.value.lastUpdatedAt > rhs.value.lastUpdatedAt
            }
            .map(\.key)

        var removed: [String] = []
        for id in sortedIDs.dropFirst(maxStoredContexts) {
            if let stored = contextsByID[id] {
                contextIDByTuple.removeValue(forKey: stored.tupleKey)
            }
            contextsByID.removeValue(forKey: id)
            removed.append(id)
        }
        return removed
    }

    private func refreshSummaries() {
        contextSummaries = contextsByID
            .values
            .sorted { lhs, rhs in
                lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            .map { stored in
                PromptRewriteConversationContextSummary(
                    id: stored.context.id,
                    displayName: stored.context.displayName,
                    appName: stored.context.appName,
                    screenLabel: stored.context.screenLabel,
                    fieldLabel: stored.context.fieldLabel,
                    projectLabel: stored.context.projectLabel,
                    identityLabel: stored.context.identityLabel,
                    lastUpdatedAt: stored.lastUpdatedAt,
                    turnCount: stored.turns.count
                )
            }
    }

    private func loadFromSQLite() {
        guard FeatureFlags.conversationTupleSQLiteEnabled else {
            contextsByID = [:]
            contextIDByTuple = [:]
            return
        }
        guard let store = resolvedSQLiteStore() else {
            contextsByID = [:]
            contextIDByTuple = [:]
            return
        }

        let threadRows = (try? store.fetchConversationThreads(limit: 500)) ?? []
        var nextContexts: [String: StoredContext] = [:]
        var nextTupleMap: [ConversationThreadTupleKey: String] = [:]

        for thread in threadRows {
            let turns = ((try? store.fetchConversationTurns(threadID: thread.id, limit: 300)) ?? [])
                .compactMap(conversationTurn(from:))
            let tags = ConversationTupleTags(
                projectKey: thread.projectKey,
                projectLabel: thread.projectLabel,
                identityKey: thread.identityKey,
                identityType: thread.identityType,
                identityLabel: thread.identityLabel,
                people: thread.people,
                nativeThreadKey: thread.nativeThreadKey
            )
            let context = PromptRewriteConversationContext(
                id: thread.id,
                appName: thread.appName,
                bundleIdentifier: thread.bundleID,
                screenLabel: thread.screenLabel,
                fieldLabel: thread.fieldLabel,
                logicalSurfaceKey: thread.logicalSurfaceKey,
                projectKey: thread.projectKey,
                projectLabel: thread.projectLabel,
                identityKey: thread.identityKey,
                identityType: thread.identityType,
                identityLabel: thread.identityLabel,
                nativeThreadKey: thread.nativeThreadKey,
                people: thread.people
            )
            let tupleKey = tagInferenceService.tupleKey(
                capturedContext: context,
                tags: tags
            )
            if let canonicalThreadID = nextTupleMap[tupleKey],
               var canonical = nextContexts[canonicalThreadID] {
                var seenTurnKeys = Set<String>()
                let mergedTurns = (canonical.turns + turns)
                    .sorted { lhs, rhs in
                        lhs.timestamp < rhs.timestamp
                    }
                    .filter { turn in
                        let dedupeKey = [
                            "\(Int((turn.timestamp.timeIntervalSince1970 * 1_000).rounded()))",
                            turn.isSummary ? "1" : "0",
                            turn.userText.lowercased(),
                            turn.assistantText.lowercased()
                        ].joined(separator: "|")
                        if seenTurnKeys.contains(dedupeKey) {
                            return false
                        }
                        seenTurnKeys.insert(dedupeKey)
                        return true
                    }
                canonical.turns = Array(mergedTurns.suffix(maxStoredTurnsPerContext))
                if thread.lastActivityAt > canonical.lastUpdatedAt {
                    canonical.lastUpdatedAt = thread.lastActivityAt
                }
                canonical.totalExchangeTurns = max(
                    canonical.totalExchangeTurns,
                    thread.totalExchangeTurns,
                    canonical.turns.filter { !$0.isSummary }.count
                )
                nextContexts[canonicalThreadID] = canonical
                continue
            }
            let canonicalContext = PromptRewriteConversationContext(
                id: thread.id,
                appName: thread.appName,
                bundleIdentifier: tupleKey.bundleID,
                screenLabel: thread.screenLabel,
                fieldLabel: thread.fieldLabel,
                logicalSurfaceKey: tupleKey.logicalSurfaceKey,
                projectKey: thread.projectKey,
                projectLabel: thread.projectLabel,
                identityKey: thread.identityKey,
                identityType: thread.identityType,
                identityLabel: thread.identityLabel,
                nativeThreadKey: thread.nativeThreadKey,
                people: thread.people
            )
            nextContexts[thread.id] = StoredContext(
                context: canonicalContext,
                turns: turns,
                lastUpdatedAt: thread.lastActivityAt,
                tupleKey: tupleKey,
                totalExchangeTurns: max(
                    thread.totalExchangeTurns,
                    turns.filter { !$0.isSummary }.count
                )
            )
            nextTupleMap[tupleKey] = thread.id
        }

        contextsByID = nextContexts
        contextIDByTuple = nextTupleMap
    }

    private func persistContext(_ stored: StoredContext) {
        guard FeatureFlags.conversationTupleSQLiteEnabled else { return }
        guard let store = resolvedSQLiteStore() else { return }

        let runningSummary = stored.turns.reversed().first(where: \.isSummary)?.assistantText ?? ""
        let exchangeTurnCount = max(stored.totalExchangeTurns, stored.turns.filter { !$0.isSummary }.count)
        let thread = ConversationThreadRecord(
            id: stored.context.id,
            appName: stored.context.appName,
            bundleID: stored.tupleKey.bundleID,
            logicalSurfaceKey: stored.tupleKey.logicalSurfaceKey,
            screenLabel: stored.context.screenLabel,
            fieldLabel: stored.context.fieldLabel,
            projectKey: stored.context.projectKey ?? "project:unknown",
            projectLabel: stored.context.projectLabel ?? "Unknown Project",
            identityKey: stored.context.identityKey ?? "identity:unknown",
            identityType: stored.context.identityType ?? "unknown",
            identityLabel: stored.context.identityLabel ?? "Unknown Identity",
            nativeThreadKey: stored.tupleKey.nativeThreadKey,
            people: stored.context.people,
            runningSummary: runningSummary,
            totalExchangeTurns: exchangeTurnCount,
            createdAt: stored.turns.first?.timestamp ?? stored.lastUpdatedAt,
            lastActivityAt: stored.lastUpdatedAt,
            updatedAt: Date()
        )

        let turnRecords = stored.turns.map { turn in
            conversationTurnRecord(
                turn,
                threadID: stored.context.id
            )
        }

        do {
            try store.upsertConversationThread(thread)
            try store.replaceConversationTurns(
                threadID: stored.context.id,
                turns: turnRecords,
                runningSummary: runningSummary,
                totalExchangeTurns: exchangeTurnCount,
                lastActivityAt: stored.lastUpdatedAt,
                updatedAt: Date()
            )
            try mergeDuplicateThreadsIfNeeded(for: stored.context.id, tupleKey: stored.tupleKey)
        } catch {
            // Best-effort persistence to avoid blocking rewrite flow.
        }
    }

    private func deleteContextFromSQLite(id: String) {
        guard FeatureFlags.conversationTupleSQLiteEnabled else { return }
        guard let store = resolvedSQLiteStore() else { return }
        try? store.deleteConversationThread(id: id)
    }

    private func clearAllContextsInSQLite() {
        guard FeatureFlags.conversationTupleSQLiteEnabled else { return }
        guard let store = resolvedSQLiteStore() else { return }
        try? store.clearAllConversationThreads()
    }

    private func resolvedSQLiteStore() -> MemorySQLiteStore? {
        if let sqliteStore {
            return sqliteStore
        }
        guard let created = try? sqliteStoreFactory() else {
            return nil
        }
        sqliteStore = created
        return created
    }

    private func mergeDuplicateThreadsIfNeeded(
        for canonicalThreadID: String,
        tupleKey: ConversationThreadTupleKey
    ) throws {
        guard let store = resolvedSQLiteStore() else { return }
        let threads = try store.fetchConversationThreads(limit: 500)
        let duplicates = threads.filter {
            $0.id != canonicalThreadID
                && $0.bundleID.caseInsensitiveCompare(tupleKey.bundleID) == .orderedSame
                && $0.logicalSurfaceKey.caseInsensitiveCompare(tupleKey.logicalSurfaceKey) == .orderedSame
                && $0.projectKey.caseInsensitiveCompare(tupleKey.projectKey) == .orderedSame
                && $0.identityKey.caseInsensitiveCompare(tupleKey.identityKey) == .orderedSame
                && $0.nativeThreadKey.caseInsensitiveCompare(tupleKey.nativeThreadKey) == .orderedSame
        }
        guard !duplicates.isEmpty else { return }
        for duplicate in duplicates {
            try store.upsertConversationThreadRedirect(
                oldThreadID: duplicate.id,
                newThreadID: canonicalThreadID,
                reason: "Merged duplicate tuple thread."
            )
            try store.deleteConversationThread(id: duplicate.id)
            contextsByID.removeValue(forKey: duplicate.id)
        }
    }

    private func collapsedWhitespace(_ value: String) -> String {
        let parts = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private func conversationTurn(from record: ConversationTurnRecord) -> PromptRewriteConversationTurn? {
        if record.isSummary {
            return PromptRewriteConversationTurn(
                userText: "Compacted conversation summary",
                assistantText: record.assistantText,
                timestamp: record.createdAt,
                isSummary: true,
                sourceTurnCount: max(1, record.sourceTurnCount),
                compactionVersion: record.compactionVersion
            )
        }
        let normalizedUser = collapsedWhitespace(record.userText)
        let normalizedAssistant = sanitizedAssistantTurnText(
            record.assistantText,
            originalUserText: normalizedUser
        )
        guard !normalizedUser.isEmpty, !normalizedAssistant.isEmpty else {
            return nil
        }
        return PromptRewriteConversationTurn(
            userText: normalizedUser,
            assistantText: normalizedAssistant,
            timestamp: record.createdAt,
            isSummary: false
        )
    }

    private func conversationTurnRecord(
        _ turn: PromptRewriteConversationTurn,
        threadID: String
    ) -> ConversationTurnRecord {
        let turnRole = turn.isSummary ? "summary" : "assistant"
        let normalized = collapsedWhitespace("\(turn.userText) \(turn.assistantText)")
        let dedupeSeed = [
            threadID,
            turnRole,
            normalized.lowercased(),
            turn.isSummary ? "1" : "0",
            "\(max(1, turn.sourceTurnCount ?? 1))",
            "\(Int((turn.timestamp.timeIntervalSince1970 * 1_000).rounded()))"
        ].joined(separator: "|")
        let dedupeKey = MemoryIdentifier.stableHexDigest(for: dedupeSeed)
        let turnID = "turn-\(dedupeKey.prefix(24))-\(Int(turn.timestamp.timeIntervalSince1970))"
        return ConversationTurnRecord(
            id: turnID,
            threadID: threadID,
            role: turnRole,
            userText: turn.userText,
            assistantText: turn.assistantText,
            normalizedText: normalized,
            isSummary: turn.isSummary,
            sourceTurnCount: max(1, turn.sourceTurnCount ?? 1),
            compactionVersion: turn.compactionVersion,
            metadata: [:],
            createdAt: turn.timestamp,
            turnDedupeKey: dedupeKey
        )
    }

    private func estimatedContextCharacters(_ turns: [PromptRewriteConversationTurn]) -> Int {
        turns.reduce(into: 0) { partial, turn in
            partial += turn.userText.count
            partial += turn.assistantText.count
        }
    }

    private func sanitizedStoredTurn(_ turn: PromptRewriteConversationTurn) -> PromptRewriteConversationTurn? {
        if turn.isSummary {
            let normalizedSummary = collapsedWhitespace(turn.assistantText)
            guard !normalizedSummary.isEmpty else { return nil }
            return PromptRewriteConversationTurn(
                userText: "Compacted conversation summary",
                assistantText: normalizedSummary,
                timestamp: turn.timestamp,
                isSummary: true,
                sourceTurnCount: turn.sourceTurnCount,
                compactionVersion: turn.compactionVersion
            )
        }

        let normalizedUser = collapsedWhitespace(turn.userText)
        let normalizedAssistant = sanitizedAssistantTurnText(
            turn.assistantText,
            originalUserText: normalizedUser
        )
        guard !normalizedUser.isEmpty, !normalizedAssistant.isEmpty else {
            return nil
        }
        return PromptRewriteConversationTurn(
            userText: normalizedUser,
            assistantText: normalizedAssistant,
            timestamp: turn.timestamp,
            isSummary: false
        )
    }

    private func sanitizedAssistantTurnText(_ value: String, originalUserText: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let strippedContextLeak = strippedTeamsContextLeak(from: trimmed)
        let strippedCommandSuffix = strippedCommandInstructionSuffix(
            from: strippedContextLeak,
            originalUserText: originalUserText
        )
        let normalizedCandidate = strippedCommandSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else { return "" }

        let lowered = normalizedCandidate.lowercased()
        let metadataMarkers = [
            "original prompt:",
            "conversation context",
            "recent conversation turns",
            "rewrite lessons payload",
            "supporting memory cards payload"
        ]
        let markerMatches = metadataMarkers.reduce(into: 0) { partial, marker in
            if lowered.contains(marker) {
                partial += 1
            }
        }

        if markerMatches >= 2,
           let extracted = extractedPromptBody(from: normalizedCandidate) {
            return collapsedWhitespace(extracted)
        }

        return collapsedWhitespace(normalizedCandidate)
    }

    private func strippedCommandInstructionSuffix(from suggestion: String, originalUserText: String) -> String {
        if mentionsCommandInstruction(originalUserText) {
            return suggestion
        }

        var lines = suggestion.components(separatedBy: .newlines)
        while let last = lines.last,
              looksLikeCommandInstructionLine(last) {
            lines.removeLast()
        }
        let output = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return suggestion }

        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)^(.*?)(?:[\s\n\r]+|[.!?]\s+)\s*>?\s*(?:run|execute|use)\s+(?:the\s+)?command\s*:\s*[^\n]{1,220}\s*$"#,
            options: []
        ) else {
            return output
        }
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let keptRange = Range(match.range(at: 1), in: output) else {
            return output
        }

        let kept = String(output[keptRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if kept.count >= 12 {
            return kept
        }
        return output
    }

    private func looksLikeCommandInstructionLine(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\s*>+\s*"#, with: "", options: .regularExpression)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized.range(
            of: #"^(?:run|execute|use)\s+(?:the\s+)?command\s*:"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if normalized.hasPrefix("open command palette")
            || normalized.hasPrefix("in command palette")
            || normalized.hasPrefix("press cmd+shift+p")
            || normalized.hasPrefix("press command+shift+p") {
            return true
        }

        return false
    }

    private func mentionsCommandInstruction(_ text: String) -> Bool {
        let normalized = collapsedWhitespace(text).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("run the command:")
            || normalized.contains("execute the command:")
            || normalized.contains("use the command:")
            || normalized.contains("command palette")
            || normalized.contains("cmd+shift+p")
            || normalized.contains("command+shift+p") {
            return true
        }
        return false
    }

    private func strippedTeamsContextLeak(from value: String) -> String {
        var output = value

        if let prefixRegex = try? NSRegularExpression(
            pattern: #"(?is)^\s*(?:in|for)\s+microsoft\s+teams,\s*project:\s*[^\n]{0,260}\b(?:type a message|focused input)\b[,:;\-\s]*"#,
            options: []
        ) {
            let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
            output = prefixRegex.stringByReplacingMatches(in: output, options: [], range: fullRange, withTemplate: "")
        }

        if let suffixRegex = try? NSRegularExpression(
            pattern: #"(?is)\s+in\s+microsoft\s+teams,\s*project:\s*[^\n]{0,260}$"#,
            options: []
        ) {
            let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
            output = suffixRegex.stringByReplacingMatches(in: output, options: [], range: fullRange, withTemplate: "")
        }

        return output
    }

    private func extractedPromptBody(from value: String) -> String? {
        let pattern = #"(?is)Original\s*prompt\s*:\s*(.+?)(?:\n\s*Conversation\s*context|\n\s*Recent\s*conversation\s*turns|\n\s*Rewrite\s*lessons\s*payload|\n\s*Supporting\s*memory\s*cards\s*payload|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func snippet(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 3))) + "..."
    }

    private func enqueueConversationPromotion(
        context: PromptRewriteConversationContext,
        summaryText: String,
        sourceTurnCount: Int,
        compactionVersion: Int?,
        trigger: MemoryPromotionTrigger,
        recentTurns: [PromptRewriteConversationTurn],
        timestamp: Date
    ) {
        let tupleTags: ConversationTupleTags?
        if let projectKey = context.projectKey,
           let projectLabel = context.projectLabel,
           let identityKey = context.identityKey,
           let identityType = context.identityType,
           let identityLabel = context.identityLabel {
            tupleTags = ConversationTupleTags(
                projectKey: projectKey,
                projectLabel: projectLabel,
                identityKey: identityKey,
                identityType: identityType,
                identityLabel: identityLabel,
                people: context.people,
                nativeThreadKey: context.nativeThreadKey ?? ""
            )
        } else {
            tupleTags = nil
        }

        let payload = ConversationMemoryPromotionPayload(
            threadID: context.id,
            tupleTags: tupleTags,
            context: context,
            summaryText: summaryText,
            sourceTurnCount: max(1, sourceTurnCount),
            compactionVersion: compactionVersion,
            trigger: trigger,
            recentTurns: recentTurns,
            timestamp: timestamp
        )
        Task {
            await ConversationMemoryPromotionService.shared.promote(payload)
        }
    }
}

enum PromptRewriteConversationContextResolver {
    static func captureCurrentContext(
        fallbackApp: NSRunningApplication?,
        screenLabel: String? = nil
    ) -> PromptRewriteConversationContext {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app: NSRunningApplication?
        if let frontmost,
           frontmost.processIdentifier != selfPID {
            app = frontmost
        } else if let fallbackApp,
           fallbackApp.processIdentifier != selfPID,
           !fallbackApp.isTerminated {
            app = fallbackApp
        } else {
            app = nil
        }

        let appName = normalizedLabel(app?.localizedName) ?? "Current App"
        let bundleID = normalizedLabel(app?.bundleIdentifier) ?? "unknown.app"

        let metadata = focusedElementMetadata(app: app)
        let preferredScreenLabel = normalizedLabel(screenLabel)
        let inferredScreenLabel = normalizedLabel(metadata.windowTitle) ?? normalizedLabel(metadata.documentLabel)
        let screenLabel: String
        if let preferredScreenLabel,
           preferredScreenLabel.caseInsensitiveCompare("Current Screen") != .orderedSame,
           !preferredScreenLabel.isEmpty {
            screenLabel = preferredScreenLabel
        } else {
            screenLabel = inferredScreenLabel ?? "Current Screen"
        }
        let fieldLabel = metadata.fieldLabel ?? "Focused Input"

        let signature = [
            bundleID.lowercased(),
            collapsedWhitespace(screenLabel).lowercased(),
            collapsedWhitespace(fieldLabel).lowercased()
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(signature.utf8))
        let digestPrefix = digest.map { String(format: "%02x", $0) }.joined().prefix(20)
        let logicalSurfaceKey = "surface-\(digestPrefix)"
        let contextID = "ctx-\(digestPrefix)"

        return PromptRewriteConversationContext(
            id: contextID,
            appName: appName,
            bundleIdentifier: bundleID,
            screenLabel: snippet(screenLabel, limit: 56),
            fieldLabel: snippet(fieldLabel, limit: 48),
            logicalSurfaceKey: logicalSurfaceKey
        )
    }

    private struct FocusMetadata {
        let windowTitle: String?
        let documentLabel: String?
        let fieldLabel: String?
    }

    private static func focusedElementMetadata(app: NSRunningApplication?) -> FocusMetadata {
        guard AXIsProcessTrusted() else {
            return FocusMetadata(windowTitle: nil, documentLabel: nil, fieldLabel: nil)
        }

        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedElement = axElementAttribute(kAXFocusedUIElementAttribute as CFString, from: systemWide) else {
            return FocusMetadata(
                windowTitle: normalizedLabel(frontmostFocusedWindowTitle()),
                documentLabel: nil,
                fieldLabel: nil
            )
        }

        let role = axStringAttribute(kAXRoleAttribute as CFString, from: focusedElement)
        let subrole = axStringAttribute(kAXSubroleAttribute as CFString, from: focusedElement)
        let title = axStringAttribute(kAXTitleAttribute as CFString, from: focusedElement)
        let identifier = axStringAttribute(kAXIdentifierAttribute as CFString, from: focusedElement)
        let description = axStringAttribute(kAXDescriptionAttribute as CFString, from: focusedElement)
        let placeholder = axStringAttribute(kAXPlaceholderValueAttribute as CFString, from: focusedElement)

        let fieldComponents = [title, placeholder, identifier, description, role]
            .compactMap(normalizedLabel)
            .filter { !$0.isEmpty }
        let fieldLabel: String?
        if let first = fieldComponents.first {
            if let subrole = normalizedLabel(subrole), !subrole.isEmpty,
               !first.localizedCaseInsensitiveContains(subrole) {
                fieldLabel = "\(first) (\(subrole))"
            } else {
                fieldLabel = first
            }
        } else if let role = normalizedLabel(role), !role.isEmpty {
            if let subrole = normalizedLabel(subrole), !subrole.isEmpty {
                fieldLabel = "\(role) (\(subrole))"
            } else {
                fieldLabel = role
            }
        } else {
            fieldLabel = nil
        }

        let windowElement = axElementAttribute(kAXWindowAttribute as CFString, from: focusedElement)
        let windowTitle = windowElement.flatMap { axStringAttribute(kAXTitleAttribute as CFString, from: $0) }
            ?? frontmostFocusedWindowTitle()
        let documentPath = windowElement.flatMap { axStringAttribute(kAXDocumentAttribute as CFString, from: $0) }
        let documentLabel = documentPath.flatMap(deriveDocumentLabel)
        let codexContextLabel = codexContextLabel(
            app: app,
            windowElement: windowElement,
            fallbackWindowTitle: windowTitle
        )
        let resolvedWindowTitle = codexContextLabel ?? windowTitle

        return FocusMetadata(
            windowTitle: normalizedLabel(resolvedWindowTitle),
            documentLabel: documentLabel,
            fieldLabel: fieldLabel
        )
    }

    private struct AXTextNode {
        let text: String
        let role: String
        let selected: Bool
    }

    private static func codexContextLabel(
        app: NSRunningApplication?,
        windowElement: AXUIElement?,
        fallbackWindowTitle: String?
    ) -> String? {
        guard isCodexApp(app), let windowElement else { return nil }
        let inferred = inferCodexProjectAndThread(
            from: windowElement,
            fallbackWindowTitle: fallbackWindowTitle
        )
        var segments: [String] = []
        if let project = inferred.project,
           !project.isEmpty {
            segments.append("Project: \(project)")
        }
        if let thread = inferred.thread,
           !thread.isEmpty {
            segments.append("Thread: \(thread)")
        }
        guard !segments.isEmpty else { return nil }
        CrashReporter.logInfo(
            """
            Codex context inferred \
            project=\(inferred.project ?? "nil") \
            thread=\(inferred.thread ?? "nil")
            """
        )
        return segments.joined(separator: " | ")
    }

    private static func inferCodexProjectAndThread(
        from windowElement: AXUIElement,
        fallbackWindowTitle: String?
    ) -> (project: String?, thread: String?) {
        let textNodes = collectTextNodes(from: windowElement, limit: 1200)
        let allTexts = textNodes.map(\.text)
        let selectedTexts = textNodes
            .filter { $0.selected }
            .map(\.text)

        var project = allTexts.compactMap(projectName(fromCodexText:)).first
        let threadFromSelected = selectedTexts.first {
            looksLikeCodexThreadTitle($0, project: project)
        }
        var thread = threadFromSelected

        if let fallbackWindowTitle = normalizedLabel(fallbackWindowTitle),
           let fromWindow = codexThreadFromWindowTitle(
               fallbackWindowTitle,
               project: project
           ) {
            thread = thread ?? fromWindow
            if project == nil {
                project = codexProjectFromWindowTitle(fallbackWindowTitle, thread: fromWindow)
            }
        }

        return (project, thread)
    }

    private static func collectTextNodes(from root: AXUIElement, limit: Int) -> [AXTextNode] {
        var queue: [AXUIElement] = [root]
        var cursor = 0
        var nodes: [AXTextNode] = []
        var seen = Set<String>()

        while cursor < queue.count, cursor < limit {
            let element = queue[cursor]
            cursor += 1

            let role = axStringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            let selected = axBoolAttribute(kAXSelectedAttribute as CFString, from: element) ?? false
            let values = [
                axStringAttribute(kAXTitleAttribute as CFString, from: element),
                axStringValueAttribute(kAXValueAttribute as CFString, from: element),
                axStringAttribute(kAXDescriptionAttribute as CFString, from: element),
                axStringAttribute(kAXHelpAttribute as CFString, from: element)
            ]
                .compactMap(normalizedLabel)

            for value in values where isLikelyCodexContextText(value) {
                let key = "\(value.lowercased())|\(role.lowercased())|\(selected)"
                if seen.insert(key).inserted {
                    nodes.append(AXTextNode(text: value, role: role, selected: selected))
                }
            }

            let children = axElementsAttribute(kAXChildrenAttribute as CFString, from: element)
            if !children.isEmpty, queue.count < limit {
                queue.append(contentsOf: children.prefix(max(0, limit - queue.count)))
            }
        }

        return nodes
    }

    private static func isLikelyCodexContextText(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if normalized.count < 3 || normalized.count > 140 {
            return false
        }

        let lowered = normalized.lowercased()
        let blocked: Set<String> = [
            "codex",
            "new thread",
            "threads",
            "automations",
            "skills",
            "settings",
            "open",
            "commit",
            "local",
            "full access",
            "show more",
            "gpt-5.3-codex",
            "extra high"
        ]
        if blocked.contains(lowered) {
            return false
        }
        if lowered.hasPrefix("ask for follow-up changes") {
            return false
        }
        return true
    }

    private static func projectName(fromCodexText text: String) -> String? {
        if let captured = firstRegexCapture(
            pattern: #"(?i)\blet['’]s\s+build\s+([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
            in: text
        ) {
            return normalizedProjectName(captured)
        }
        if let captured = firstRegexCapture(
            pattern: #"(?i)\b(?:project|workspace)\s*[:\-]\s*([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
            in: text
        ) {
            return normalizedProjectName(captured)
        }
        return nil
    }

    private static func normalizedProjectName(_ value: String) -> String? {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else { return nil }
        let lowered = normalized.lowercased()
        let blocked: Set<String> = ["thread", "new thread", "current thread", "codex"]
        if blocked.contains(lowered) {
            return nil
        }
        return normalized
    }

    private static func looksLikeCodexThreadTitle(_ value: String, project: String?) -> Bool {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        if lowered.hasPrefix("project:") || lowered.hasPrefix("workspace:") {
            return false
        }
        if let project, normalized.caseInsensitiveCompare(project) == .orderedSame {
            return false
        }
        let blocked: Set<String> = [
            "new thread",
            "threads",
            "settings",
            "automations",
            "skills",
            "show more",
            "open",
            "commit"
        ]
        if blocked.contains(lowered) {
            return false
        }
        return normalized.count >= 4
    }

    private static func codexThreadFromWindowTitle(_ title: String, project: String?) -> String? {
        let normalizedTitle = collapsedWhitespace(title)
        guard !normalizedTitle.isEmpty else { return nil }
        let cleaned = normalizedTitle
            .replacingOccurrences(of: #"(?i)\bcodex\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !cleaned.isEmpty else { return nil }

        if let project {
            let loweredCleaned = cleaned.lowercased()
            let loweredProject = project.lowercased()
            if loweredCleaned.hasSuffix(loweredProject) {
                let cutoff = cleaned.index(cleaned.endIndex, offsetBy: -project.count)
                var prefix = String(cleaned[..<cutoff])
                prefix = prefix.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                if looksLikeCodexThreadTitle(prefix, project: project) {
                    return prefix
                }
            }
        }

        if looksLikeCodexThreadTitle(cleaned, project: project) {
            return cleaned
        }
        return nil
    }

    private static func codexProjectFromWindowTitle(_ title: String, thread: String) -> String? {
        let normalizedTitle = collapsedWhitespace(title)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalizedTitle.isEmpty, !thread.isEmpty else { return nil }
        if normalizedTitle.caseInsensitiveCompare(thread) == .orderedSame {
            return nil
        }
        let loweredTitle = normalizedTitle.lowercased()
        let loweredThread = thread.lowercased()
        if loweredTitle.hasPrefix(loweredThread) {
            let suffixStart = normalizedTitle.index(normalizedTitle.startIndex, offsetBy: thread.count)
            let suffix = String(normalizedTitle[suffixStart...])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            return normalizedProjectName(suffix)
        }
        return nil
    }

    private static func firstRegexCapture(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        let captured = String(value[captureRange])
        return normalizedLabel(captured)
    }

    private static func isCodexApp(_ app: NSRunningApplication?) -> Bool {
        let bundleID = app?.bundleIdentifier?.lowercased() ?? ""
        let appName = app?.localizedName?.lowercased() ?? ""
        if bundleID == "com.openai.codex" {
            return true
        }
        return appName == "codex" || appName.contains("codex")
    }

    private static func frontmostFocusedWindowTitle() -> String? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != selfPID else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        if let focusedWindow = axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement),
           let title = axStringAttribute(kAXTitleAttribute as CFString, from: focusedWindow),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        if let firstWindow = axElementFromArrayAttribute(kAXWindowsAttribute as CFString, from: appElement),
           let title = axStringAttribute(kAXTitleAttribute as CFString, from: firstWindow),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        return nil
    }

    private static func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(valueRef, to: AXUIElement.self)
    }

    private static func axElementFromArrayAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              let array = valueRef as? [Any] else {
            return nil
        }
        for item in array {
            guard CFGetTypeID(item as CFTypeRef) == AXUIElementGetTypeID() else { continue }
            return unsafeBitCast(item as CFTypeRef, to: AXUIElement.self)
        }
        return nil
    }

    private static func axElementsAttribute(_ attribute: CFString, from element: AXUIElement) -> [AXUIElement] {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              let array = valueRef as? [Any] else {
            return []
        }

        var elements: [AXUIElement] = []
        elements.reserveCapacity(array.count)
        for item in array {
            let cf = item as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { continue }
            elements.append(unsafeBitCast(cf, to: AXUIElement.self))
        }
        return elements
    }

    private static func axStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }
        return valueRef as? String
    }

    private static func axStringValueAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef else {
            return nil
        }
        if let stringValue = valueRef as? String {
            return stringValue
        }
        if let attributed = valueRef as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private static func axBoolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef else {
            return nil
        }
        if let boolValue = valueRef as? Bool {
            return boolValue
        }
        if let number = valueRef as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private static func normalizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = collapsedWhitespace(raw)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func deriveDocumentLabel(from rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            if url.isFileURL {
                let name = url.deletingPathExtension().lastPathComponent
                return normalizedLabel(name)
            }
            if let host = url.host, !host.isEmpty {
                return normalizedLabel(host)
            }
            return normalizedLabel(url.lastPathComponent)
        }

        let fileURL = URL(fileURLWithPath: trimmed)
        let name = fileURL.deletingPathExtension().lastPathComponent
        return normalizedLabel(name)
    }

    private static func snippet(_ value: String, limit: Int) -> String {
        let normalized = collapsedWhitespace(value)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }
}
