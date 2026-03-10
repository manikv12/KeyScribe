import XCTest
@testable import KeyScribe

final class AssistantOrbHUDModelTests: XCTestCase {
    @MainActor
    func testCompletionPopupSurvivesIdleTransitionUntilUserDismissesIt() {
        let model = AssistantOrbHUDModel()

        model.update(
            state: AssistantHUDState(
                phase: .success,
                title: "Finished",
                detail: "Grouped invoices into monthly folders."
            )
        )

        XCTAssertTrue(model.showDoneDetail)
        XCTAssertEqual(model.doneDetailText, "Grouped invoices into monthly folders.")

        model.update(state: .idle)

        XCTAssertTrue(model.showDoneDetail)
        XCTAssertEqual(model.doneDetailText, "Grouped invoices into monthly folders.")

        model.dismissDoneDetail()

        XCTAssertFalse(model.showDoneDetail)
        XCTAssertNil(model.doneDetailText)
    }

    @MainActor
    func testNewWorkClearsPreviousCompletionPopup() {
        let model = AssistantOrbHUDModel()

        model.update(
            state: AssistantHUDState(
                phase: .success,
                title: "Finished",
                detail: "Cleaned up the selected files."
            )
        )

        model.update(
            state: AssistantHUDState(
                phase: .streaming,
                title: "Working",
                detail: nil
            )
        )

        XCTAssertFalse(model.showDoneDetail)
        XCTAssertNil(model.doneDetailText)
    }

    @MainActor
    func testWorkingPopupCanOpenDuringActiveTurnAndClosesWhenIdle() {
        let model = AssistantOrbHUDModel()
        model.activeSessionSummary = AssistantSessionSummary(
            id: "session-1",
            title: "Downloads cleanup",
            source: .appServer,
            status: .active,
            cwd: "/Users/test/Downloads"
        )

        model.update(
            state: AssistantHUDState(
                phase: .acting,
                title: "Working",
                detail: "Running git status"
            )
        )

        XCTAssertTrue(model.presentWorkingDetailIfAvailable())
        XCTAssertTrue(model.showWorkingDetail)

        model.update(state: .idle)

        XCTAssertFalse(model.showWorkingDetail)
    }

    @MainActor
    func testSelectSessionForReplyTargetsSessionWithoutShowingPreview() {
        let model = AssistantOrbHUDModel()
        model.isExpanded = true
        model.showPreview("Old preview")

        let session = AssistantSessionSummary(
            id: "session-2",
            title: "General Chat",
            source: .appServer,
            status: .completed,
            latestAssistantMessage: "Ready when you are."
        )

        model.selectSessionForReply(session)

        XCTAssertEqual(model.selectedSessionID, "session-2")
        XCTAssertTrue(model.isExpanded)
        XCTAssertFalse(model.showDoneDetail)
        XCTAssertNil(model.doneDetailText)
    }

    @MainActor
    func testShowFollowUpPreviewSelectsSessionAndShowsLatestAssistantReply() {
        let model = AssistantOrbHUDModel()
        model.isExpanded = true

        let session = AssistantSessionSummary(
            id: "session-3",
            title: "Calendar",
            source: .appServer,
            status: .completed,
            latestAssistantMessage: "You have one meeting tomorrow at 9 AM."
        )

        model.showFollowUpPreview(for: session)

        XCTAssertEqual(model.selectedSessionID, "session-3")
        XCTAssertFalse(model.isExpanded)
        XCTAssertTrue(model.showDoneDetail)
        XCTAssertEqual(model.doneDetailText, "You have one meeting tomorrow at 9 AM.")
    }

    @MainActor
    func testShowFollowUpPreviewWithoutAssistantReplyKeepsOrbExpanded() {
        let model = AssistantOrbHUDModel()
        model.isExpanded = true

        let session = AssistantSessionSummary(
            id: "session-4",
            title: "Empty Session",
            source: .appServer,
            status: .completed,
            latestAssistantMessage: nil
        )

        model.showFollowUpPreview(for: session)

        XCTAssertEqual(model.selectedSessionID, "session-4")
        XCTAssertTrue(model.isExpanded)
        XCTAssertFalse(model.showDoneDetail)
        XCTAssertNil(model.doneDetailText)
    }

    @MainActor
    func testLevelUpdatesAreSmoothedAndStayWithinBounds() {
        let model = AssistantOrbHUDModel()

        model.updateLevel(1.5)
        let firstRise = model.level

        model.updateLevel(1.0)
        let secondRise = model.level

        model.updateLevel(-1.0)
        let softenedFall = model.level

        XCTAssertGreaterThan(firstRise, 0)
        XCTAssertLessThan(firstRise, 1)
        XCTAssertGreaterThan(secondRise, firstRise)
        XCTAssertLessThanOrEqual(secondRise, 1)
        XCTAssertLessThan(softenedFall, secondRise)
        XCTAssertGreaterThanOrEqual(softenedFall, 0)
    }

    @MainActor
    func testCycleInteractionModeMatchesMainViewOrder() {
        let model = AssistantOrbHUDModel()
        var changes: [AssistantInteractionMode] = []

        model.onModeChanged = { mode in
            changes.append(mode)
        }

        model.cycleInteractionMode()
        XCTAssertEqual(model.interactionMode, .plan)

        model.cycleInteractionMode()
        XCTAssertEqual(model.interactionMode, .agentic)

        model.cycleInteractionMode()
        XCTAssertEqual(model.interactionMode, .conversational)
        XCTAssertEqual(changes, [.plan, .agentic, .conversational])
    }

    @MainActor
    func testOrbDraftPlanRequestSuggestsSwitchToPlanMode() {
        let model = AssistantOrbHUDModel()

        model.messageText = "Please plan this before coding."

        XCTAssertEqual(model.modeSwitchSuggestion?.source, .draft)
        XCTAssertEqual(model.modeSwitchSuggestion?.choices.map(\.mode), [.plan])
    }
}
