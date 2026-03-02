import Foundation
import XCTest
@testable import KeyScribe

final class ConversationMemoryArchivePromotionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testTimeoutPruneCreatesExpiredRecordAndDeletesActiveContext() throws {
        let store = try makeIsolatedStore()
        let now = Date()
        let threadID = "thread-timeout-\(UUID().uuidString)"
        let scopeKey = makeScopeKey(
            bundleID: "com.apple.dt.xcode",
            surface: "Project Editor",
            projectName: "KeyScribe",
            identityKey: "thread:timeout-bug"
        )

        try store.upsertConversationThread(
            ConversationThreadRecord(
                id: threadID,
                appName: "Xcode",
                bundleID: "com.apple.dt.xcode",
                logicalSurfaceKey: "surface-project-editor",
                screenLabel: "Editor",
                fieldLabel: "Prompt",
                projectKey: "project:keyscribe",
                projectLabel: "KeyScribe",
                identityKey: "thread:timeout-bug",
                identityType: "channel",
                identityLabel: "Timeout Bug",
                nativeThreadKey: "thread:timeout-bug",
                people: [],
                runningSummary: "",
                totalExchangeTurns: 2,
                createdAt: now.addingTimeInterval(-500),
                lastActivityAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-300)
            )
        )

        try store.replaceConversationTurns(
            threadID: threadID,
            turns: [
                makeConversationTurn(
                    threadID: threadID,
                    userText: "Investigate timeout prune path",
                    assistantText: "Checking stale context handling.",
                    createdAt: now.addingTimeInterval(-320)
                )
            ],
            runningSummary: "Timeout prune investigation.",
            totalExchangeTurns: 1,
            lastActivityAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-300)
        )

        try store.upsertExpiredConversationContext(
            ExpiredConversationContextRecord(
                id: "expired-\(UUID().uuidString)",
                scopeKey: scopeKey,
                threadID: threadID,
                bundleID: "com.apple.dt.xcode",
                projectKey: "project:keyscribe",
                identityKey: "thread:timeout-bug",
                summaryText: "Timeout prune archived this handoff summary.",
                summaryMethod: .fallback,
                summaryConfidence: nil,
                sourceTurnCount: 2,
                recentTurnsJSON: "[]",
                rawTurnsJSON: "[\"timeout prune raw turn\"]",
                trigger: "timeout",
                expiredAt: now.addingTimeInterval(-240),
                deleteAfterAt: now.addingTimeInterval(86_400),
                consumedAt: nil,
                consumedByThreadID: nil,
                metadata: ["promotion_decision": "promote"]
            )
        )

        try store.deleteConversationThread(id: threadID)

        XCTAssertNil(try store.fetchConversationThread(id: threadID))

        let archived = try store.fetchLatestExpiredConversationContext(
            scopeKey: scopeKey,
            bundleIDConstraint: "com.apple.dt.xcode"
        )
        XCTAssertNotNil(archived)
        XCTAssertEqual(archived?.threadID, threadID)
        XCTAssertEqual(archived?.trigger, "timeout")
    }

    func testAISummaryUpdateBefore60SecondsUpgradesMethod() async throws {
        let databaseURL = try makeIsolatedDatabaseURL()
        let provider = ControlledRewriteProvider(
            handoffResult: (
                text: "AI handoff summary generated quickly with concrete next steps.",
                confidence: 0.92,
                method: "ai-test"
            )
        )
        let promotionService = ConversationMemoryPromotionService(
            rewriteProvider: provider,
            storeFactory: { try MemorySQLiteStore(databaseURL: databaseURL) }
        )

        let payload = makePromotionPayload(
            summaryText: "Fallback summary that should be replaced by AI.",
            fallbackSummaryText: "Fallback summary that should be replaced by AI.",
            trigger: .manualCompaction,
            sourceTurnCount: 8
        )

        try await withConversationPromotionFlagsEnabled {
            await promotionService.promote(payload)
        }

        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let cards = try store.fetchCardsForRewrite(query: "AI handoff summary", options: .init(limit: 20))
        guard let card = cards.first else {
            XCTFail("Expected promoted card with AI summary metadata.")
            return
        }

        XCTAssertTrue(card.summary.localizedCaseInsensitiveContains("AI handoff summary"))
        XCTAssertEqual(card.metadata["summary_method"], "ai-test")
        XCTAssertEqual(card.metadata["ai_timeout_seconds"], "60")
    }

    func testTimeoutOrFailureKeepsFallbackSummary() async throws {
        let databaseURL = try makeIsolatedDatabaseURL()
        let provider = ControlledRewriteProvider(
            handoffResult: (
                text: "",
                confidence: nil,
                method: "deterministic-timeout-fallback"
            )
        )
        let promotionService = ConversationMemoryPromotionService(
            rewriteProvider: provider,
            storeFactory: { try MemorySQLiteStore(databaseURL: databaseURL) }
        )

        let fallback = "Fallback handoff summary remains when AI times out."
        let payload = makePromotionPayload(
            summaryText: fallback,
            fallbackSummaryText: fallback,
            trigger: .manualCompaction,
            sourceTurnCount: 6
        )

        try await withConversationPromotionFlagsEnabled {
            await promotionService.promote(payload)
        }

        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let cards = try store.fetchCardsForRewrite(query: "Fallback handoff summary remains", options: .init(limit: 20))
        guard let card = cards.first else {
            XCTFail("Expected promoted card using fallback summary.")
            return
        }

        XCTAssertTrue(card.summary.localizedCaseInsensitiveContains("Fallback handoff summary remains"))
        XCTAssertEqual(card.metadata["summary_method"], "deterministic-timeout-fallback")
    }

    func testRehydrationInjectsExpiredSummaryIntoNextMatchingRequestContext() throws {
        let store = try makeIsolatedStore()
        let scopeKey = makeScopeKey(
            bundleID: "com.keyscribe.coding-workspace",
            surface: "Coding Workspace",
            projectName: "KeyScribe",
            identityKey: "thread:rehydration"
        )
        let now = Date()
        let expiredID = "expired-\(UUID().uuidString)"

        try store.upsertExpiredConversationContext(
            ExpiredConversationContextRecord(
                id: expiredID,
                scopeKey: scopeKey,
                threadID: "thread-legacy",
                bundleID: "com.keyscribe.coding-workspace",
                projectKey: "project:keyscribe",
                identityKey: "thread:rehydration",
                summaryText: "Inject this summary into the next matching context.",
                summaryMethod: .fallback,
                summaryConfidence: nil,
                sourceTurnCount: 4,
                recentTurnsJSON: "[]",
                rawTurnsJSON: "[\"rehydration raw\"]",
                trigger: "timeout",
                expiredAt: now.addingTimeInterval(-15),
                deleteAfterAt: now.addingTimeInterval(86_400),
                consumedAt: nil,
                consumedByThreadID: nil,
                metadata: [:]
            )
        )

        let pending = try store.fetchLatestExpiredConversationContext(
            scopeKey: scopeKey,
            bundleIDConstraint: "com.keyscribe.coding-workspace"
        )
        XCTAssertEqual(pending?.id, expiredID)
        XCTAssertEqual(pending?.summaryText, "Inject this summary into the next matching context.")

        let markedConsumed = try store.markExpiredConversationContextConsumed(
            id: expiredID,
            consumedByThreadID: "thread-new-target"
        )
        XCTAssertTrue(markedConsumed)

        let afterConsume = try store.fetchLatestExpiredConversationContext(
            scopeKey: scopeKey,
            bundleIDConstraint: "com.keyscribe.coding-workspace"
        )
        XCTAssertNil(afterConsume)
    }

    func testScopeMatchingWithCrossIDEOnOff() throws {
        let inference = ConversationTagInferenceService.shared
        let tags = ConversationTupleTags(
            projectKey: "project:keyscribe",
            projectLabel: "KeyScribe",
            identityKey: "thread:bug-123",
            identityType: "channel",
            identityLabel: "Bug 123"
        )
        let xcodeContext = makeContext(
            threadID: "thread-xcode",
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            screenLabel: "Editor",
            fieldLabel: "Prompt"
        )
        let codexContext = makeContext(
            threadID: "thread-codex",
            appName: "Codex",
            bundleID: "com.openai.codex",
            screenLabel: "Editor",
            fieldLabel: "Prompt"
        )

        withEnvironment(
            values: ["KEYSCRIBE_FEATURE_CROSS_IDE_CONVERSATION_SHARING": "1"]
        ) {
            let onTupleXcode = inference.tupleKey(capturedContext: xcodeContext, tags: tags)
            let onTupleCodex = inference.tupleKey(capturedContext: codexContext, tags: tags)

            XCTAssertEqual(onTupleXcode.bundleID, onTupleCodex.bundleID)
            XCTAssertEqual(onTupleXcode.logicalSurfaceKey, onTupleCodex.logicalSurfaceKey)
            XCTAssertEqual(
                inference.threadID(for: onTupleXcode),
                inference.threadID(for: onTupleCodex)
            )
        }

        withEnvironment(
            values: ["KEYSCRIBE_FEATURE_CROSS_IDE_CONVERSATION_SHARING": "0"]
        ) {
            let offTupleXcode = inference.tupleKey(capturedContext: xcodeContext, tags: tags)
            let offTupleCodex = inference.tupleKey(capturedContext: codexContext, tags: tags)

            XCTAssertNotEqual(offTupleXcode.bundleID, offTupleCodex.bundleID)
            XCTAssertNotEqual(
                inference.threadID(for: offTupleXcode),
                inference.threadID(for: offTupleCodex)
            )
        }
    }

    func testPromotionScoringPassFail() async throws {
        let databaseURL = try makeIsolatedDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let promotionService = ConversationMemoryPromotionService(
            rewriteProvider: ControlledRewriteProvider(
                handoffResult: (
                    text: "Structured summary with actionable implementation details.",
                    confidence: 0.88,
                    method: "ai-test"
                )
            ),
            storeFactory: { try MemorySQLiteStore(databaseURL: databaseURL) }
        )

        let passPayload = makePromotionPayload(
            summaryText: """
            ## Handoff
            - Implement promotion diagnostics in the UI.
            - Add tests and verify behavior.
            """,
            fallbackSummaryText: nil,
            trigger: .autoCompaction,
            sourceTurnCount: 18,
            context: makeContext(
                threadID: "thread-pass",
                appName: "Xcode",
                bundleID: "com.apple.dt.xcode",
                screenLabel: "AIMemoryStudio",
                fieldLabel: "Conversation Memory"
            ),
            promotionScopeKey: "scope|com.apple.dt.xcode|ai-memory|project:keyscribe|-|channel|thread:promotion-pass"
        )
        let passDecision = await promotionService.evaluatePromotionSignals(payload: passPayload, store: store)
        XCTAssertTrue(passDecision.shouldPromote)
        XCTAssertEqual(passDecision.decision, "promote")
        XCTAssertGreaterThanOrEqual(passDecision.score, passDecision.threshold)

        let failPayload = makePromotionPayload(
            summaryText: "tiny",
            fallbackSummaryText: nil,
            trigger: .timeout,
            sourceTurnCount: 1,
            context: makeContext(
                threadID: "thread-fail",
                appName: "Current App",
                bundleID: "com.example.unknown",
                screenLabel: "Current Screen",
                fieldLabel: "Focused Input",
                projectKey: "project:unknown",
                projectLabel: "Unknown Project",
                identityKey: "identity:unknown",
                identityType: "unknown",
                identityLabel: "Unknown Identity"
            ),
            promotionScopeKey: nil,
            recentTurns: [
                PromptRewriteConversationTurn(
                    userText: "hi",
                    assistantText: "ok"
                )
            ],
            rawTurns: [
                PromptRewriteConversationTurn(
                    userText: "hi",
                    assistantText: "ok"
                )
            ]
        )
        let failDecision = await promotionService.evaluatePromotionSignals(payload: failPayload, store: store)
        XCTAssertFalse(failDecision.shouldPromote)
        XCTAssertEqual(failDecision.decision, "skip")
        XCTAssertLessThan(failDecision.score, failDecision.threshold)
    }

    func testManualTriggersAlwaysPromote() async throws {
        let databaseURL = try makeIsolatedDatabaseURL()
        let provider = ControlledRewriteProvider(
            handoffResult: (
                text: "manual trigger summary",
                confidence: nil,
                method: "deterministic-fallback"
            )
        )
        let promotionService = ConversationMemoryPromotionService(
            rewriteProvider: provider,
            storeFactory: { try MemorySQLiteStore(databaseURL: databaseURL) }
        )

        let manualPayload = makePromotionPayload(
            summaryText: "short",
            fallbackSummaryText: "short",
            trigger: .manualCompaction,
            sourceTurnCount: 1
        )
        let scoreStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let decision = await promotionService.evaluatePromotionSignals(payload: manualPayload, store: scoreStore)
        XCTAssertTrue(decision.forcePromote)
        XCTAssertTrue(decision.shouldPromote)
        XCTAssertEqual(decision.decision, "force-promote")

        try await withConversationPromotionFlagsEnabled {
            await promotionService.promote(manualPayload)
            await promotionService.promote(
                makePromotionPayload(
                    summaryText: "short",
                    fallbackSummaryText: "short",
                    trigger: .manualPin,
                    sourceTurnCount: 1,
                    threadID: "thread-manual-pin-\(UUID().uuidString)"
                )
            )
        }

        let verificationStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let cards = try verificationStore.fetchCardsForRewrite(query: "", options: .init(limit: 20))
        let triggers = Set(cards.compactMap { $0.metadata["trigger"] })
        XCTAssertTrue(triggers.contains(MemoryPromotionTrigger.manualCompaction.rawValue))
        XCTAssertTrue(triggers.contains(MemoryPromotionTrigger.manualPin.rawValue))
    }

    func testRetentionPurgeByAgeRowByteCaps() throws {
        let store = try makeIsolatedStore()
        let now = Date()
        let scopeKey = makeScopeKey(
            bundleID: "com.apple.dt.xcode",
            surface: "Purge Test Surface",
            projectName: "KeyScribe",
            identityKey: "thread:retention"
        )

        try store.upsertExpiredConversationContext(
            makeExpiredRecord(
                id: "expired-age-\(UUID().uuidString)",
                scopeKey: scopeKey,
                threadID: "thread-expired",
                bundleID: "com.apple.dt.xcode",
                summaryText: "Delete by delete_after cutoff.",
                expiredAt: now.addingTimeInterval(-3_600),
                deleteAfterAt: now.addingTimeInterval(-10),
                rawTurnsJSON: "[\"raw-expired\"]"
            )
        )
        try store.upsertExpiredConversationContext(
            makeExpiredRecord(
                id: "retention-age-\(UUID().uuidString)",
                scopeKey: scopeKey,
                threadID: "thread-retention",
                bundleID: "com.apple.dt.xcode",
                summaryText: "Delete by retention age.",
                expiredAt: now.addingTimeInterval(-20 * 86_400),
                deleteAfterAt: now.addingTimeInterval(20 * 86_400),
                rawTurnsJSON: "[\"raw-retention\"]"
            )
        )

        for index in 0..<4 {
            try store.upsertExpiredConversationContext(
                makeExpiredRecord(
                    id: "overflow-\(index)-\(UUID().uuidString)",
                    scopeKey: scopeKey,
                    threadID: "thread-overflow-\(index)",
                    bundleID: "com.apple.dt.xcode",
                    summaryText: "Overflow record \(index)",
                    expiredAt: now.addingTimeInterval(-Double(120 + index * 30)),
                    deleteAfterAt: now.addingTimeInterval(40 * 86_400),
                    rawTurnsJSON: "[\"\(String(repeating: "x", count: 140))\"]"
                )
            )
        }

        let purge = try store.purgeExpiredConversationContextArchive(
            now: now,
            retentionDays: 10,
            maxRows: 3,
            maxRawBytes: 180
        )
        XCTAssertEqual(purge.expiredDeleted, 1)
        XCTAssertEqual(purge.retentionDeleted, 1)
        XCTAssertEqual(purge.rowLimitDeleted, 1)
        XCTAssertGreaterThanOrEqual(purge.rawSizeDeleted, 1)

        let secondPurge = try store.purgeExpiredConversationContextArchive(
            now: now,
            retentionDays: 10,
            maxRows: 3,
            maxRawBytes: 180
        )
        XCTAssertEqual(secondPurge.expiredDeleted, 0)
        XCTAssertEqual(secondPurge.retentionDeleted, 0)
        XCTAssertEqual(secondPurge.rowLimitDeleted, 0)
        XCTAssertEqual(secondPurge.rawSizeDeleted, 0)
    }

    private func makeIsolatedStore() throws -> MemorySQLiteStore {
        let databaseURL = try makeIsolatedDatabaseURL()
        return try MemorySQLiteStore(databaseURL: databaseURL)
    }

    private func makeIsolatedDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyScribeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("memory.sqlite3")
    }

    private func makeConversationTurn(
        threadID: String,
        userText: String,
        assistantText: String,
        createdAt: Date
    ) -> ConversationTurnRecord {
        ConversationTurnRecord(
            id: "turn-\(UUID().uuidString)",
            threadID: threadID,
            role: "assistant",
            userText: userText,
            assistantText: assistantText,
            normalizedText: "\(userText) \(assistantText)",
            isSummary: false,
            sourceTurnCount: 1,
            compactionVersion: nil,
            metadata: [:],
            createdAt: createdAt,
            turnDedupeKey: "dedupe-\(UUID().uuidString)"
        )
    }

    private func makeScopeKey(
        bundleID: String,
        surface: String,
        projectName: String?,
        identityKey: String?
    ) -> String {
        MemoryScopeContext.makeScopeKey(
            bundleID: bundleID,
            surfaceLabel: surface,
            projectName: projectName,
            repositoryName: nil,
            identityKey: identityKey,
            identityType: "channel"
        )
    }

    private func makeExpiredRecord(
        id: String,
        scopeKey: String,
        threadID: String,
        bundleID: String,
        summaryText: String,
        expiredAt: Date,
        deleteAfterAt: Date,
        rawTurnsJSON: String
    ) -> ExpiredConversationContextRecord {
        ExpiredConversationContextRecord(
            id: id,
            scopeKey: scopeKey,
            threadID: threadID,
            bundleID: bundleID,
            projectKey: "project:keyscribe",
            identityKey: "thread:retention",
            summaryText: summaryText,
            summaryMethod: .fallback,
            summaryConfidence: nil,
            sourceTurnCount: 3,
            recentTurnsJSON: "[]",
            rawTurnsJSON: rawTurnsJSON,
            trigger: "timeout",
            expiredAt: expiredAt,
            deleteAfterAt: deleteAfterAt,
            consumedAt: nil,
            consumedByThreadID: nil,
            metadata: [:]
        )
    }

    private func makePromotionPayload(
        summaryText: String,
        fallbackSummaryText: String?,
        trigger: MemoryPromotionTrigger,
        sourceTurnCount: Int,
        context: PromptRewriteConversationContext? = nil,
        promotionScopeKey: String? = "scope|com.apple.dt.xcode|editor|project:keyscribe|-|channel|thread:promotion",
        recentTurns: [PromptRewriteConversationTurn] = [
            PromptRewriteConversationTurn(
                userText: "Please implement promotion diagnostics and run tests.",
                assistantText: "Implemented diagnostics and added tests with verification details."
            ),
            PromptRewriteConversationTurn(
                userText: "Ensure timeout fallback remains stable.",
                assistantText: "Fallback summary remains when AI is unavailable."
            )
        ],
        rawTurns: [PromptRewriteConversationTurn]? = nil,
        threadID: String = "thread-\(UUID().uuidString)"
    ) -> ConversationMemoryPromotionPayload {
        ConversationMemoryPromotionPayload(
            threadID: threadID,
            tupleTags: ConversationTupleTags(
                projectKey: "project:keyscribe",
                projectLabel: "KeyScribe",
                identityKey: "thread:promotion",
                identityType: "channel",
                identityLabel: "Promotion"
            ),
            context: context ?? makeContext(),
            summaryText: summaryText,
            fallbackSummaryText: fallbackSummaryText,
            rawTurns: rawTurns ?? recentTurns,
            promotionScopeKey: promotionScopeKey,
            summaryGenerationMetadata: [:],
            sourceTurnCount: sourceTurnCount,
            trigger: trigger,
            recentTurns: recentTurns,
            timestamp: Date()
        )
    }

    private func makeContext(
        threadID: String = "thread-base",
        appName: String = "Xcode",
        bundleID: String = "com.apple.dt.xcode",
        screenLabel: String = "Editor",
        fieldLabel: String = "Prompt",
        projectKey: String = "project:keyscribe",
        projectLabel: String = "KeyScribe",
        identityKey: String = "thread:promotion",
        identityType: String = "channel",
        identityLabel: String = "Promotion"
    ) -> PromptRewriteConversationContext {
        PromptRewriteConversationContext(
            id: threadID,
            appName: appName,
            bundleIdentifier: bundleID,
            screenLabel: screenLabel,
            fieldLabel: fieldLabel,
            logicalSurfaceKey: "surface-\(screenLabel.lowercased())",
            projectKey: projectKey,
            projectLabel: projectLabel,
            identityKey: identityKey,
            identityType: identityType,
            identityLabel: identityLabel,
            nativeThreadKey: identityKey,
            people: ["Manik"]
        )
    }

    private func withConversationPromotionFlagsEnabled(
        operation: () async throws -> Void
    ) async throws {
        try await withEnvironment(
            values: [
                "KEYSCRIBE_FEATURE_AI_MEMORY": "1",
                "KEYSCRIBE_FEATURE_CONVERSATION_LONG_TERM_MEMORY": "1",
                "KEYSCRIBE_FEATURE_CONVERSATION_AUTO_PROMOTION": "1"
            ],
            operation: operation
        )
    }

    private func withEnvironment(
        values: [String: String],
        operation: () throws -> Void
    ) rethrows {
        var previous: [String: String?] = [:]
        previous.reserveCapacity(values.count)
        for key in values.keys {
            previous[key] = currentEnvironmentValue(for: key)
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                restoreEnvironmentValue(value, for: key)
            }
        }
        try operation()
    }

    private func withEnvironment(
        values: [String: String],
        operation: () async throws -> Void
    ) async rethrows {
        var previous: [String: String?] = [:]
        previous.reserveCapacity(values.count)
        for key in values.keys {
            previous[key] = currentEnvironmentValue(for: key)
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                restoreEnvironmentValue(value, for: key)
            }
        }
        try await operation()
    }

    private func currentEnvironmentValue(for key: String) -> String? {
        guard let pointer = getenv(key) else { return nil }
        return String(cString: pointer)
    }

    private func restoreEnvironmentValue(_ value: String?, for key: String) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}

private final class ControlledRewriteProvider: MemoryRewriteExtractionProviding {
    private let handoffResult: (text: String, confidence: Double?, method: String)

    init(handoffResult: (text: String, confidence: Double?, method: String)) {
        self.handoffResult = handoffResult
    }

    func summary(for draft: MemoryEventDraft, provider: MemoryProviderKind) async -> String? {
        _ = draft
        _ = provider
        return nil
    }

    func rewriteSuggestion(
        for draft: MemoryEventDraft,
        card: MemoryCard,
        provider: MemoryProviderKind
    ) async -> RewriteSuggestion? {
        _ = draft
        _ = card
        _ = provider
        return nil
    }

    func lesson(
        for draft: MemoryEventDraft,
        card: MemoryCard,
        provider: MemoryProviderKind
    ) async -> MemoryLessonDraft? {
        _ = draft
        _ = card
        _ = provider
        return nil
    }

    func summarizeConversationHandoff(
        summarySeed: String,
        recentTurns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext,
        timeoutSeconds: Int
    ) async -> (text: String, confidence: Double?, method: String) {
        _ = summarySeed
        _ = recentTurns
        _ = context
        _ = timeoutSeconds
        return handoffResult
    }

    func hasAIBackedIndexingAccess(for provider: MemoryProviderKind) async -> Bool {
        _ = provider
        return true
    }
}
