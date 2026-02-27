import Foundation

struct ConversationMemoryPromotionPayload {
    let threadID: String
    let tupleTags: ConversationTupleTags?
    let context: PromptRewriteConversationContext
    let summaryText: String
    let sourceTurnCount: Int
    let compactionVersion: Int?
    let trigger: MemoryPromotionTrigger
    let recentTurns: [PromptRewriteConversationTurn]
    let timestamp: Date

    init(
        threadID: String,
        tupleTags: ConversationTupleTags? = nil,
        context: PromptRewriteConversationContext,
        summaryText: String,
        sourceTurnCount: Int,
        compactionVersion: Int? = nil,
        trigger: MemoryPromotionTrigger,
        recentTurns: [PromptRewriteConversationTurn],
        timestamp: Date = Date()
    ) {
        self.threadID = threadID
        self.tupleTags = tupleTags
        self.context = context
        self.summaryText = summaryText
        self.sourceTurnCount = sourceTurnCount
        self.compactionVersion = compactionVersion
        self.trigger = trigger
        self.recentTurns = recentTurns
        self.timestamp = timestamp
    }
}

actor ConversationMemoryPromotionService {
    static let shared = ConversationMemoryPromotionService()

    private let rewriteProvider: MemoryRewriteExtractionProviding
    private let storeFactory: @Sendable () throws -> MemorySQLiteStore
    private var store: MemorySQLiteStore?

    init(
        rewriteProvider: MemoryRewriteExtractionProviding = StubMemoryRewriteExtractionProvider.shared,
        storeFactory: @escaping @Sendable () throws -> MemorySQLiteStore = { try MemorySQLiteStore() }
    ) {
        self.rewriteProvider = rewriteProvider
        self.storeFactory = storeFactory
    }

    func promote(_ payload: ConversationMemoryPromotionPayload) async {
        guard FeatureFlags.aiMemoryEnabled,
              FeatureFlags.conversationLongTermMemoryEnabled,
              FeatureFlags.conversationAutoPromotionEnabled else {
            return
        }

        let normalizedSummary = MemoryTextNormalizer.normalizedBody(payload.summaryText)
        guard !normalizedSummary.isEmpty else { return }
        let nativeThreadKey = MemoryTextNormalizer.collapsedWhitespace(
            payload.tupleTags?.nativeThreadKey ?? payload.context.nativeThreadKey ?? ""
        ).lowercased()

        do {
            let store = try resolvedStore()
            let scope = inferScopeContext(from: payload)
            let promotionSignature = promotionSignature(for: payload, scope: scope)

            let sourceID = MemoryIdentifier.stableUUID(
                for: "source|conversation-history|\(scope.bundleID)"
            )
            let sourceFileID = MemoryIdentifier.stableUUID(
                for: "file|\(sourceID.uuidString)|\(scope.scopeKey)"
            )
            let eventID = MemoryIdentifier.stableUUID(
                for: "event|conversation-history|\(promotionSignature)"
            )
            let cardID = MemoryIdentifier.stableUUID(
                for: "card|conversation-history|\(promotionSignature)"
            )

            let source = MemorySource(
                id: sourceID,
                provider: .unknown,
                rootPath: "internal://conversation-history/\(scope.bundleID)",
                displayName: "\(scope.appName) Conversation Memory",
                discoveredAt: payload.timestamp,
                metadata: [
                    "origin": "conversation-history",
                    "scope_key": scope.scopeKey,
                    "app_name": scope.appName,
                    "bundle_id": scope.bundleID,
                    "surface_label": scope.surfaceLabel,
                    "project_name": scope.projectName ?? "",
                    "repository_name": scope.repositoryName ?? "",
                    "identity_key": scope.identityKey ?? "",
                    "identity_type": scope.identityType ?? "",
                    "identity_label": scope.identityLabel ?? "",
                    "native_thread_key": nativeThreadKey,
                    "thread_id": payload.threadID,
                    "trigger": payload.trigger.rawValue
                ]
            )
            try store.upsertSource(source)

            let sourceFile = MemorySourceFile(
                id: sourceFileID,
                sourceID: sourceID,
                absolutePath: "conversation-history/\(scope.scopeKey).jsonl",
                relativePath: "conversation-history/\(scope.scopeKey).jsonl",
                fileHash: promotionSignature,
                fileSizeBytes: Int64(normalizedSummary.utf8.count),
                modifiedAt: payload.timestamp,
                indexedAt: payload.timestamp,
                parseError: nil
            )
            try store.upsertSourceFile(sourceFile)

            let eventBody = buildEventBody(summary: normalizedSummary, recentTurns: payload.recentTurns)
            let eventKeywords = MemoryTextNormalizer.keywords(
                from: "\(scope.appName) \(scope.surfaceLabel) \(scope.projectName ?? "") \(scope.repositoryName ?? "") \(normalizedSummary)",
                limit: 20
            )
            let event = MemoryEvent(
                id: eventID,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                provider: .unknown,
                kind: .summary,
                title: MemoryTextNormalizer.normalizedTitle(
                    "\(scope.appName) memory: \(scope.surfaceLabel)",
                    fallback: "Conversation Memory Summary"
                ),
                body: eventBody,
                timestamp: payload.timestamp,
                nativeSummary: MemoryTextNormalizer.normalizedSummary(normalizedSummary, limit: 260),
                keywords: eventKeywords,
                isPlanContent: false,
                metadata: [
                    "origin": "conversation-history",
                    "scope_key": scope.scopeKey,
                    "app_name": scope.appName,
                    "bundle_id": scope.bundleID,
                    "surface_label": scope.surfaceLabel,
                    "project_name": scope.projectName ?? "",
                    "repository_name": scope.repositoryName ?? "",
                    "identity_key": scope.identityKey ?? "",
                    "identity_type": scope.identityType ?? "",
                    "identity_label": scope.identityLabel ?? "",
                    "native_thread_key": nativeThreadKey,
                    "thread_id": payload.threadID,
                    "source_turn_count": "\(max(1, payload.sourceTurnCount))",
                    "compaction_version": payload.compactionVersion.map(String.init) ?? "",
                    "trigger": payload.trigger.rawValue
                ],
                rawPayload: nil
            )
            try store.upsertEvent(event)

            let card = MemoryCard(
                id: cardID,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                eventID: eventID,
                provider: .unknown,
                title: event.title,
                summary: MemoryTextNormalizer.normalizedSummary(normalizedSummary, limit: 220),
                detail: eventBody,
                keywords: eventKeywords,
                score: scoreForPromotion(payload),
                createdAt: payload.timestamp,
                updatedAt: payload.timestamp,
                isPlanContent: false,
                metadata: event.metadata
            )
            try store.upsertCard(card)

            let draft = MemoryEventDraft(
                kind: .summary,
                title: event.title,
                body: eventBody,
                timestamp: payload.timestamp,
                nativeSummary: card.summary,
                keywords: eventKeywords,
                isPlanContent: false,
                metadata: event.metadata,
                rawPayload: nil
            )

            var lessonID: UUID?
            var patternKey: String
            if let lessonDraft = await rewriteProvider.lesson(for: draft, card: card, provider: .unknown) {
                let lesson = MemoryLesson(
                    id: MemoryIdentifier.stableUUID(
                        for: "lesson|conversation-history|\(promotionSignature)|\(lessonDraft.mistakePattern)|\(lessonDraft.improvedPrompt)"
                    ),
                    sourceID: sourceID,
                    sourceFileID: sourceFileID,
                    eventID: eventID,
                    cardID: cardID,
                    provider: .unknown,
                    mistakePattern: lessonDraft.mistakePattern,
                    improvedPrompt: lessonDraft.improvedPrompt,
                    rationale: lessonDraft.rationale,
                    validationConfidence: lessonDraft.validationConfidence,
                    sourceMetadata: mergedMetadata(
                        base: lessonDraft.sourceMetadata,
                        scope: scope,
                        trigger: payload.trigger,
                        contextID: payload.threadID,
                        sourceTurnCount: payload.sourceTurnCount,
                        compactionVersion: payload.compactionVersion,
                        nativeThreadKey: nativeThreadKey
                    ),
                    createdAt: payload.timestamp,
                    updatedAt: payload.timestamp
                )
                try store.upsertLesson(lesson)
                try store.supersedeCompetingLessons(
                    with: lesson,
                    reason: "Superseded by newer conversation summary lesson.",
                    timestamp: payload.timestamp
                )
                lessonID = lesson.id

                let suggestion = RewriteSuggestion(
                    id: MemoryIdentifier.stableUUID(
                        for: "rewrite|conversation-history|\(promotionSignature)|\(lessonDraft.mistakePattern)|\(lessonDraft.improvedPrompt)"
                    ),
                    cardID: cardID,
                    provider: .unknown,
                    originalText: MemoryTextNormalizer.collapsedWhitespace(lessonDraft.mistakePattern),
                    suggestedText: MemoryTextNormalizer.collapsedWhitespace(lessonDraft.improvedPrompt),
                    rationale: lessonDraft.rationale,
                    confidence: min(1.0, max(0.0, lessonDraft.validationConfidence)),
                    createdAt: payload.timestamp
                )
                try store.insertRewriteSuggestion(suggestion)

                patternKey = MemoryIdentifier.stableHexDigest(
                    for: "pattern|\(scope.scopeKey)|\(MemoryTextNormalizer.collapsedWhitespace(lessonDraft.mistakePattern).lowercased())|\(MemoryTextNormalizer.collapsedWhitespace(lessonDraft.improvedPrompt).lowercased())"
                )
            } else {
                patternKey = MemoryIdentifier.stableHexDigest(
                    for: "pattern|\(scope.scopeKey)|summary|\(MemoryTextNormalizer.collapsedWhitespace(normalizedSummary).lowercased())"
                )
            }

            try store.recordPatternOccurrence(
                patternKey: patternKey,
                scope: scope,
                cardID: cardID,
                lessonID: lessonID,
                trigger: payload.trigger,
                outcome: .neutral,
                confidence: scoreForPromotion(payload),
                metadata: [
                    "origin": "conversation-history",
                    "thread_id": payload.threadID,
                    "native_thread_key": nativeThreadKey,
                    "identity_key": scope.identityKey ?? "",
                    "identity_type": scope.identityType ?? "",
                    "identity_label": scope.identityLabel ?? "",
                    "trigger": payload.trigger.rawValue,
                    "source_turn_count": "\(max(1, payload.sourceTurnCount))"
                ],
                timestamp: payload.timestamp
            )
        } catch {
            // Best-effort promotion: never block rewrite flow.
        }
    }

    func fetchPatternStats(scopeKey: String? = nil, limit: Int = 200) async -> [MemoryPatternStats] {
        do {
            let store = try resolvedStore()
            return try store.fetchPatternStats(scopeKey: scopeKey, limit: limit)
        } catch {
            return []
        }
    }

    func fetchPatternOccurrences(patternKey: String, limit: Int = 120) async -> [MemoryPatternOccurrence] {
        do {
            let store = try resolvedStore()
            return try store.fetchPatternOccurrences(patternKey: patternKey, limit: limit)
        } catch {
            return []
        }
    }

    @discardableResult
    func markPatternOutcome(
        patternKey: String,
        outcome: MemoryPatternOutcome,
        trigger: MemoryPromotionTrigger,
        reason: String? = nil
    ) async -> Bool {
        do {
            let store = try resolvedStore()
            guard let existing = try store.fetchPatternStats(patternKey: patternKey) else {
                return false
            }
            let scope = MemoryScopeContext(
                appName: existing.appName,
                bundleID: existing.bundleID,
                surfaceLabel: existing.surfaceLabel,
                projectName: existing.projectName,
                repositoryName: existing.repositoryName,
                scopeKey: existing.scopeKey,
                isCodingContext: inferCodingContext(
                    bundleID: existing.bundleID,
                    appName: existing.appName,
                    projectName: existing.projectName,
                    repositoryName: existing.repositoryName
                )
            )
            var metadata: [String: String] = ["origin": "manual-mark"]
            if let reason {
                metadata["reason"] = MemoryTextNormalizer.normalizedSummary(reason, limit: 180)
            }
            try store.recordPatternOccurrence(
                patternKey: patternKey,
                scope: scope,
                cardID: nil,
                lessonID: nil,
                trigger: trigger,
                outcome: outcome,
                confidence: existing.confidence,
                metadata: metadata,
                timestamp: Date()
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deletePattern(patternKey: String) async -> Bool {
        do {
            let store = try resolvedStore()
            try store.deletePattern(patternKey: patternKey)
            return true
        } catch {
            return false
        }
    }

    func purgeExpiredRetention() async -> (cardsDeleted: Int, lessonsDeleted: Int, patternsDeleted: Int, occurrencesDeleted: Int) {
        do {
            let store = try resolvedStore()
            return try store.purgeByTieredRetention()
        } catch {
            return (0, 0, 0, 0)
        }
    }

    private func resolvedStore() throws -> MemorySQLiteStore {
        if let store {
            return store
        }
        let created = try storeFactory()
        store = created
        return created
    }

    private func promotionSignature(for payload: ConversationMemoryPromotionPayload, scope: MemoryScopeContext) -> String {
        let summaryDigest = MemoryIdentifier.stableHexDigest(
            for: MemoryTextNormalizer.collapsedWhitespace(payload.summaryText).lowercased()
        )

        let base = [
            payload.threadID,
            scope.scopeKey,
            summaryDigest,
            "\(max(1, payload.sourceTurnCount))",
            payload.trigger.rawValue
        ].joined(separator: "|")
        return MemoryIdentifier.stableHexDigest(for: base)
    }

    private func scoreForPromotion(_ payload: ConversationMemoryPromotionPayload) -> Double {
        let turnsFactor = min(1.0, Double(max(1, payload.sourceTurnCount)) / 12.0)
        let triggerBoost: Double
        switch payload.trigger {
        case .manualCompaction, .manualPin:
            triggerBoost = 0.10
        case .autoCompaction:
            triggerBoost = 0.05
        case .timeout:
            triggerBoost = 0.0
        }
        return min(0.98, max(0.55, 0.62 + (turnsFactor * 0.26) + triggerBoost))
    }

    private func buildEventBody(summary: String, recentTurns: [PromptRewriteConversationTurn]) -> String {
        var lines: [String] = [
            "Conversation summary:",
            MemoryTextNormalizer.normalizedBody(summary)
        ]

        let recent = recentTurns.suffix(4)
        if !recent.isEmpty {
            lines.append("")
            lines.append("Recent turns:")
            for turn in recent {
                let timeLabel = ISO8601DateFormatter().string(from: turn.timestamp)
                if turn.isSummary {
                    lines.append("- [\(timeLabel)] Summary: \(MemoryTextNormalizer.normalizedSummary(turn.assistantText, limit: 220))")
                } else {
                    let userSnippet = MemoryTextNormalizer.normalizedSummary(turn.userText, limit: 180)
                    let assistantSnippet = MemoryTextNormalizer.normalizedSummary(turn.assistantText, limit: 180)
                    lines.append("- [\(timeLabel)] User: \(userSnippet)")
                    lines.append("  Assistant: \(assistantSnippet)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func mergedMetadata(
        base: [String: String],
        scope: MemoryScopeContext,
        trigger: MemoryPromotionTrigger,
        contextID: String,
        sourceTurnCount: Int,
        compactionVersion: Int?,
        nativeThreadKey: String
    ) -> [String: String] {
        var merged = base
        merged["origin"] = "conversation-history"
        merged["scope_key"] = scope.scopeKey
        merged["app_name"] = scope.appName
        merged["bundle_id"] = scope.bundleID
        merged["surface_label"] = scope.surfaceLabel
        merged["project_name"] = scope.projectName ?? ""
        merged["repository_name"] = scope.repositoryName ?? ""
        merged["identity_key"] = scope.identityKey ?? ""
        merged["identity_type"] = scope.identityType ?? ""
        merged["identity_label"] = scope.identityLabel ?? ""
        merged["context_id"] = contextID
        merged["thread_id"] = contextID
        merged["native_thread_key"] = nativeThreadKey
        merged["trigger"] = trigger.rawValue
        merged["source_turn_count"] = "\(max(1, sourceTurnCount))"
        if let compactionVersion {
            merged["compaction_version"] = "\(compactionVersion)"
        }
        if merged["validation_state"] == nil {
            merged["validation_state"] = MemoryRewriteLessonValidationState.unvalidated.rawValue
        }

        var normalized: [String: String] = [:]
        normalized.reserveCapacity(merged.count)
        for (key, value) in merged {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { continue }
            normalized[normalizedKey] = normalizedValue
        }
        return normalized
    }

    private func inferScopeContext(from payload: ConversationMemoryPromotionPayload) -> MemoryScopeContext {
        let context = payload.context

        if let tupleTags = payload.tupleTags {
            let isCoding = inferCodingContext(
                bundleID: context.bundleIdentifier,
                appName: context.appName,
                projectName: tupleTags.projectLabel,
                repositoryName: nil
            )
            let surfaceLabel = context.logicalSurfaceKey.isEmpty
                ? "\(context.screenLabel) • \(context.fieldLabel)"
                : context.logicalSurfaceKey
            return MemoryScopeContext(
                appName: context.appName,
                bundleID: context.bundleIdentifier,
                surfaceLabel: surfaceLabel,
                projectName: tupleTags.projectLabel,
                repositoryName: nil,
                identityKey: tupleTags.identityKey,
                identityType: tupleTags.identityType,
                identityLabel: tupleTags.identityLabel,
                isCodingContext: isCoding
            )
        }

        let combinedText = [
            context.screenLabel,
            context.fieldLabel,
            payload.summaryText,
            payload.recentTurns.map { "\($0.userText) \($0.assistantText)" }.joined(separator: "\n")
        ].joined(separator: "\n")

        let bundleID = context.bundleIdentifier
        let appName = context.appName
        let surfaceLabel = "\(context.screenLabel) • \(context.fieldLabel)"

        let pathCandidate = extractPathLikeValue(from: combinedText)
        let derivedPathLabel = pathCandidate.flatMap(derivePathLabel)
        let domainCandidate = extractDomain(from: combinedText)
        let teamsChannel = extractTeamsChannel(from: context.screenLabel)

        let isCoding = inferCodingContext(
            bundleID: bundleID,
            appName: appName,
            projectName: derivedPathLabel,
            repositoryName: nil
        )

        let projectName: String?
        let repositoryName: String?
        if isCoding {
            projectName = derivedPathLabel
            repositoryName = derivedPathLabel
        } else if isBrowser(bundleID: bundleID, appName: appName) {
            projectName = domainCandidate ?? derivedPathLabel
            repositoryName = nil
        } else if isTeams(bundleID: bundleID, appName: appName) {
            projectName = teamsChannel ?? derivedPathLabel
            repositoryName = nil
        } else {
            projectName = derivedPathLabel ?? teamsChannel ?? domainCandidate
            repositoryName = nil
        }

        return MemoryScopeContext(
            appName: appName,
            bundleID: bundleID,
            surfaceLabel: surfaceLabel,
            projectName: projectName,
            repositoryName: repositoryName,
            identityKey: context.identityKey,
            identityType: context.identityType,
            identityLabel: context.identityLabel,
            isCodingContext: isCoding
        )
    }

    private func inferCodingContext(
        bundleID: String,
        appName: String,
        projectName: String?,
        repositoryName: String?
    ) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        if ["xcode", "cursor", "vscode", "code", "jetbrains", "codex", "android.studio", "sublime", "nova"].contains(where: { value.contains($0) }) {
            return true
        }
        if let projectName, projectName.contains("/") {
            return true
        }
        if let repositoryName, repositoryName.contains("/") {
            return true
        }
        return false
    }

    private func isBrowser(bundleID: String, appName: String) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        return ["safari", "chrome", "firefox", "arc", "brave", "opera", "edge"].contains(where: { value.contains($0) })
    }

    private func isTeams(bundleID: String, appName: String) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        return value.contains("teams")
    }

    private func extractDomain(from value: String) -> String? {
        let pattern = #"(?i)\b(?:https?://)?([a-z0-9.-]+\.[a-z]{2,})(?:/|\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let domainRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        let domain = String(value[domainRange]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return nil }
        return domain
    }

    private func extractTeamsChannel(from value: String) -> String? {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value)
        guard !normalized.isEmpty else { return nil }

        let separators = ["|", "-", "•", ":"]
        for separator in separators {
            if normalized.contains(separator) {
                let parts = normalized.split(separator: Character(separator), omittingEmptySubsequences: true)
                    .map { MemoryTextNormalizer.collapsedWhitespace(String($0)) }
                    .filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let candidate = parts.prefix(2).joined(separator: " / ")
                    return MemoryTextNormalizer.normalizedSummary(candidate, limit: 80)
                }
            }
        }

        return MemoryTextNormalizer.normalizedSummary(normalized, limit: 80)
    }

    private func extractPathLikeValue(from value: String) -> String? {
        let patterns = [
            #"file://[^\s"'<>\]\[)\(,;]+"#,
            #"/(?:Users|Volumes|private)/[^\s"'<>\]\[)\(,;]{3,}"#,
            #"[A-Za-z]:\\[^\s"'<>\]\[)\(,;]{3,}"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, options: [], range: range),
                  let tokenRange = Range(match.range(at: 0), in: value) else {
                continue
            }
            var token = String(value[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>,;"))
            if let decoded = token.removingPercentEncoding,
               !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                token = decoded
            }
            if !token.isEmpty {
                return token
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
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        for component in components.reversed() {
            let lower = component.lowercased()
            if ["users", "library", "application support", "workspace", "storage", "state", "history", "sessions", "projects", "repos", "repositories", "repo", "tmp", "temp"].contains(lower) {
                continue
            }
            if component.range(of: #"\.[A-Za-z]{1,8}$"#, options: .regularExpression) != nil {
                continue
            }
            if component.range(of: #"^[0-9a-f-]{16,}$"#, options: .regularExpression) != nil {
                continue
            }
            return component
        }
        return nil
    }
}
