import XCTest
@testable import KeyScribe

final class AssistantSessionInteractionTests: XCTestCase {
    @MainActor
    func testShouldBlockSessionSwitchOnlyWhenAnotherTurnIsActive() {
        XCTAssertTrue(
            AssistantStore.shouldBlockSessionSwitch(
                activeSessionID: "session-a",
                hasActiveTurn: true,
                requestedSessionID: "session-b"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldBlockSessionSwitch(
                activeSessionID: "session-a",
                hasActiveTurn: true,
                requestedSessionID: "session-a"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldBlockSessionSwitch(
                activeSessionID: "session-a",
                hasActiveTurn: false,
                requestedSessionID: "session-b"
            )
        )
    }

    @MainActor
    func testRuntimeSuppressesNonToolActivityRows() {
        let runtime = CodexAssistantRuntime()

        XCTAssertFalse(runtime.shouldRenderActivity(for: "agentMessage"))
        XCTAssertFalse(runtime.shouldRenderActivity(for: "userMessage"))
        XCTAssertFalse(runtime.shouldRenderActivity(for: "reasoning"))
        XCTAssertFalse(runtime.shouldRenderActivity(for: "plan"))
        XCTAssertTrue(runtime.shouldRenderActivity(for: "commandExecution"))
        XCTAssertTrue(runtime.shouldRenderActivity(for: "webSearch"))
    }

    @MainActor
    func testCombinedRuntimeInstructionsIncludesOneShotPlanWithoutDroppingOtherInstructions() {
        let instructions = AssistantStore.combinedRuntimeInstructions(
            global: "Use simple language.",
            session: "Stay in the selected repo.",
            oneShot: "# Plan to Execute\n\nRun the cleanup flow."
        )

        XCTAssertEqual(
            instructions,
            """
            Use simple language.

            Stay in the selected repo.

            # Plan to Execute

            Run the cleanup flow.
            """
        )
    }

    @MainActor
    func testCombinedRuntimeInstructionsReturnsNilWhenEverySectionIsBlank() {
        XCTAssertNil(
            AssistantStore.combinedRuntimeInstructions(
                global: "  ",
                session: "\n",
                oneShot: ""
            )
        )
    }

    @MainActor
    func testInteractionModesUseExpectedOrderAndCodexModeKinds() {
        XCTAssertEqual(
            AssistantInteractionMode.allCases,
            [.conversational, .plan, .agentic]
        )

        XCTAssertEqual(AssistantInteractionMode.conversational.codexModeKind, "default")
        XCTAssertEqual(AssistantInteractionMode.plan.codexModeKind, "plan")
        XCTAssertEqual(AssistantInteractionMode.agentic.codexModeKind, "default")
    }

    @MainActor
    func testBrowserAutomationRequirementBlocksBrowserTaskUntilSetupIsReady() {
        XCTAssertEqual(
            AssistantStore.browserAutomationRequirement(
                for: "Open https://x.com and summarize the first post.",
                browserAutomationEnabled: false,
                hasSelectedBrowserProfile: false
            ),
            .enableAutomation
        )

        XCTAssertEqual(
            AssistantStore.browserAutomationRequirement(
                for: "Open https://x.com and summarize the first post.",
                browserAutomationEnabled: true,
                hasSelectedBrowserProfile: false
            ),
            .selectProfile
        )

        XCTAssertEqual(
            AssistantStore.browserAutomationRequirement(
                for: "Open https://x.com and summarize the first post.",
                browserAutomationEnabled: true,
                hasSelectedBrowserProfile: true
            ),
            .none
        )
    }

    @MainActor
    func testBrowserContextOverrideIsOnlyInjectedWhenThreadNeedsPriming() {
        XCTAssertTrue(
            AssistantStore.shouldInjectBrowserContextOverride(
                for: "Open https://x.com and summarize the first post.",
                currentBrowserSignature: "Brave Browser|Profile 1",
                primedBrowserSignature: nil
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldInjectBrowserContextOverride(
                for: "Open https://x.com and summarize the first post.",
                currentBrowserSignature: "Brave Browser|Profile 1",
                primedBrowserSignature: "Brave Browser|Profile 1"
            )
        )

        XCTAssertTrue(
            AssistantStore.shouldInjectBrowserContextOverride(
                for: "Open https://x.com and summarize the first post.",
                currentBrowserSignature: "Brave Browser|Profile 2",
                primedBrowserSignature: "Brave Browser|Profile 1"
            )
        )
    }

    @MainActor
    func testLooksLikeBrowserAutomationRequestIgnoresNonAutomationQuestion() {
        XCTAssertFalse(
            AssistantStore.looksLikeBrowserAutomationRequest(
                "Explain how browser profiles change the assistant session."
            )
        )
    }

    @MainActor
    func testBrowserTurnReminderCarriesCurrentProfileDetails() {
        let reminder = CodexAssistantRuntime.browserTurnReminder(from: [
            "browser": "Brave Browser",
            "channel": "brave",
            "profileDir": "Profile 1",
            "userDataDir": "/Users/test/Library/Application Support/BraveSoftware/Brave-Browser",
            "profileName": "Personal"
        ])

        XCTAssertNotNil(reminder)
        XCTAssertTrue(reminder?.contains("Profile: Personal") == true)
        XCTAssertTrue(reminder?.contains("Brave Browser") == true)
        XCTAssertTrue(reminder?.contains("launchPersistentContext") == true)
        XCTAssertTrue(reminder?.contains("Profile 1") == true)
    }

    @MainActor
    func testShouldPreserveProposedPlanOnlyForMatchingSession() {
        XCTAssertTrue(
            AssistantStore.shouldPreserveProposedPlan(
                planSessionID: "THREAD-123",
                activeSessionID: "thread-123"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldPreserveProposedPlan(
                planSessionID: "thread-123",
                activeSessionID: "thread-456"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldPreserveProposedPlan(
                planSessionID: "thread-123",
                activeSessionID: nil
            )
        )
    }

    @MainActor
    func testPlanExecutionSessionIDUsesOnlyPlanSession() {
        XCTAssertEqual(
            AssistantStore.planExecutionSessionID(planSessionID: "plan-thread"),
            "plan-thread"
        )
    }

    @MainActor
    func testPlanExecutionSessionIDReturnsNilWhenPlanSessionMissing() {
        XCTAssertNil(
            AssistantStore.planExecutionSessionID(planSessionID: nil)
        )

        XCTAssertNil(
            AssistantStore.planExecutionSessionID(planSessionID: " \n ")
        )
    }

    @MainActor
    func testBuildResumeContextUsesRecentMeaningfulTranscriptEntries() {
        let transcript: [AssistantTranscriptEntry] = [
            AssistantTranscriptEntry(role: .system, text: "Loaded Codex thread thread-1.", emphasis: true),
            AssistantTranscriptEntry(role: .user, text: "Can you check my Obsidian Vault Macs?"),
            AssistantTranscriptEntry(role: .assistant, text: "I found your Macs vault at ~/Documents/Vault/Macs and the Obsidian CLI is available."),
            AssistantTranscriptEntry(role: .user, text: "What all is in my obsidian vault you said?"),
            AssistantTranscriptEntry(role: .assistant, text: "Your Macs Obsidian vault currently shows these items: 2026-02-10.md and other notes.")
        ]

        let context = AssistantStore.buildResumeContext(
            transcriptEntries: transcript,
            sessionSummary: nil
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Recovered Thread Context") == true)
        XCTAssertFalse(context?.contains("Loaded Codex thread") == true)
        XCTAssertTrue(context?.contains("User: Can you check my Obsidian Vault Macs?") == true)
        XCTAssertTrue(context?.contains("Assistant: I found your Macs vault") == true)
        XCTAssertTrue(context?.contains("User: What all is in my obsidian vault you said?") == true)
    }

    @MainActor
    func testBuildResumeContextFallsBackToSessionPreviewWhenTranscriptMissing() {
        let session = AssistantSessionSummary(
            id: "thread-1",
            title: "Obsidian vault check",
            source: .appServer,
            status: .completed,
            latestUserMessage: "What all is in my obsidian vault you said?",
            latestAssistantMessage: "Your Macs Obsidian vault currently shows three items."
        )

        let context = AssistantStore.buildResumeContext(
            transcriptEntries: [],
            sessionSummary: session
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("User: What all is in my obsidian vault you said?") == true)
        XCTAssertTrue(context?.contains("Assistant: Your Macs Obsidian vault currently shows three items.") == true)
    }
}
