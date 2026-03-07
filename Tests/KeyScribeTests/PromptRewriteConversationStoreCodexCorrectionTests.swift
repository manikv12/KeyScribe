import Foundation
import XCTest
@testable import KeyScribe

@MainActor
final class PromptRewriteConversationStoreCodexCorrectionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testCodexSecondPassCorrectsUnknownProjectThreadWhenProjectAppears() throws {
        let databaseURL = try makeIsolatedDatabaseURL()
        let now = Date()
        let oldThreadID = "thread-codex-unknown-\(UUID().uuidString)"

        do {
            let seedStore = try MemorySQLiteStore(databaseURL: databaseURL)
            try seedStore.upsertConversationThread(
                ConversationThreadRecord(
                    id: oldThreadID,
                    appName: "Codex",
                    bundleID: "com.openai.codex",
                    logicalSurfaceKey: "surface-codex-unknown",
                    screenLabel: "Thread: Diagnose Codex project lookup",
                    fieldLabel: "Focused Input",
                    projectKey: "project:unknown",
                    projectLabel: "Unknown Project",
                    identityKey: "thread:diagnose-codex-project-lookup",
                    identityType: "channel",
                    identityLabel: "Diagnose Codex project lookup",
                    nativeThreadKey: "thread:diagnose-codex-project-lookup",
                    people: [],
                    runningSummary: "",
                    totalExchangeTurns: 1,
                    createdAt: now.addingTimeInterval(-120),
                    lastActivityAt: now.addingTimeInterval(-90),
                    updatedAt: now.addingTimeInterval(-90)
                )
            )
            try seedStore.replaceConversationTurns(
                threadID: oldThreadID,
                turns: [
                    makeConversationTurn(
                        threadID: oldThreadID,
                        userText: "First Codex request",
                        assistantText: "First Codex answer",
                        createdAt: now.addingTimeInterval(-100)
                    )
                ],
                runningSummary: "",
                totalExchangeTurns: 1,
                lastActivityAt: now.addingTimeInterval(-90),
                updatedAt: now.addingTimeInterval(-90)
            )
        }

        var conversationStore: PromptRewriteConversationStore? = PromptRewriteConversationStore.makeForTesting(
            sqliteStoreFactory: { try MemorySQLiteStore(databaseURL: databaseURL) }
        )
        let capturedContext = PromptRewriteConversationContext(
            id: "ctx-codex-live",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Project: KeyScribe | Thread: Diagnose Codex project lookup",
            fieldLabel: "Focused Input"
        )
        let inferredTags = ConversationTagInferenceService.shared.inferTags(
            capturedContext: capturedContext,
            userText: ""
        )
        XCTAssertEqual(inferredTags.projectKey, "project:keyscribe")
        XCTAssertEqual(inferredTags.identityKey, "thread:diagnose-codex-project-lookup")
        XCTAssertEqual(inferredTags.nativeThreadKey, "diagnose")

        let request = try XCTUnwrap(conversationStore).prepareRequestContext(
            capturedContext: capturedContext,
            userText: "Please continue",
            timeoutMinutes: 60,
            turnLimit: 10,
            pinnedContextID: nil
        )

        XCTAssertEqual(request.context.projectKey, "project:keyscribe")
        XCTAssertEqual(request.context.projectLabel, "KeyScribe")
        XCTAssertNotEqual(request.context.id, oldThreadID)
        XCTAssertEqual(request.history.count, 1)
        XCTAssertEqual(request.history.first?.userText, "First Codex request")

        try XCTUnwrap(conversationStore).recordTurn(
            originalText: "Second Codex request",
            finalText: "Second Codex answer",
            context: request.context,
            timeoutMinutes: 60,
            maxTurns: 12
        )

        conversationStore = nil

        let verificationStore = try MemorySQLiteStore(databaseURL: databaseURL)
        XCTAssertNil(try verificationStore.fetchConversationThread(id: oldThreadID))
        XCTAssertEqual(
            try verificationStore.resolveConversationThreadRedirect(oldThreadID),
            request.context.id
        )

        let correctedThread = try verificationStore.fetchConversationThread(id: request.context.id)
        XCTAssertEqual(correctedThread?.projectKey, "project:keyscribe")
        XCTAssertEqual(correctedThread?.projectLabel, "KeyScribe")

        let correctedTurns = try verificationStore.fetchConversationTurns(
            threadID: request.context.id,
            limit: 10
        )
        XCTAssertEqual(correctedTurns.count, 2)
        XCTAssertEqual(correctedTurns.first?.userText, "First Codex request")
    }

    func testCodexReusesKnownProjectForSameThreadWhenCurrentCaptureIsUnknown() throws {
        let databaseURL = try makeIsolatedDatabaseURL()
        let now = Date()
        let knownThreadID = "thread-codex-known-\(UUID().uuidString)"

        do {
            let seedStore = try MemorySQLiteStore(databaseURL: databaseURL)
            try seedStore.upsertConversationThread(
                ConversationThreadRecord(
                    id: knownThreadID,
                    appName: "Codex",
                    bundleID: "com.openai.codex",
                    logicalSurfaceKey: "surface-codex-keyscribe",
                    screenLabel: "Project: KeyScribe | Thread: Diagnose Codex project lookup",
                    fieldLabel: "Focused Input",
                    projectKey: "project:keyscribe",
                    projectLabel: "KeyScribe",
                    identityKey: "thread:diagnose-codex-project-lookup",
                    identityType: "channel",
                    identityLabel: "Diagnose Codex project lookup",
                    nativeThreadKey: "diagnose",
                    people: [],
                    runningSummary: "",
                    totalExchangeTurns: 1,
                    createdAt: now.addingTimeInterval(-120),
                    lastActivityAt: now.addingTimeInterval(-60),
                    updatedAt: now.addingTimeInterval(-60)
                )
            )
            try seedStore.replaceConversationTurns(
                threadID: knownThreadID,
                turns: [
                    makeConversationTurn(
                        threadID: knownThreadID,
                        userText: "Known project request",
                        assistantText: "Known project answer",
                        createdAt: now.addingTimeInterval(-80)
                    )
                ],
                runningSummary: "",
                totalExchangeTurns: 1,
                lastActivityAt: now.addingTimeInterval(-60),
                updatedAt: now.addingTimeInterval(-60)
            )
        }

        let conversationStore = PromptRewriteConversationStore.makeForTesting(
            sqliteStoreFactory: { try MemorySQLiteStore(databaseURL: databaseURL) }
        )
        let capturedContext = PromptRewriteConversationContext(
            id: "ctx-codex-live-unknown",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Thread: Diagnose Codex project lookup",
            fieldLabel: "Focused Input"
        )

        let request = conversationStore.prepareRequestContext(
            capturedContext: capturedContext,
            userText: "Please continue",
            timeoutMinutes: 60,
            turnLimit: 10,
            pinnedContextID: nil
        )

        XCTAssertEqual(request.context.projectKey, "project:keyscribe")
        XCTAssertEqual(request.context.projectLabel, "KeyScribe")
        XCTAssertEqual(request.context.id, knownThreadID)
        XCTAssertEqual(request.history.count, 1)
        XCTAssertEqual(request.history.first?.userText, "Known project request")
    }

    private func makeIsolatedDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyScribeCodexTests-\(UUID().uuidString)", isDirectory: true)
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
}
