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
}
