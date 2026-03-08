import XCTest
@testable import KeyScribe

final class AssistantPermissionCardStateTests: XCTestCase {
    func testMatchingPendingRequestStaysWaitingForApproval() {
        let request = AssistantPermissionRequest(
            id: 42,
            sessionID: "session-1",
            toolTitle: "browser_click",
            toolKind: "playwright",
            rationale: "Allow the click?",
            options: [],
            rawPayloadSummary: nil
        )

        XCTAssertEqual(
            assistantPermissionCardState(
                for: request,
                pendingRequest: request,
                sessionStatus: .completed
            ),
            .waitingForApproval
        )
    }

    func testMatchingPendingUserInputRequestStaysWaitingForInput() {
        let request = AssistantPermissionRequest(
            id: 42,
            sessionID: "session-1",
            toolTitle: "User input needed",
            toolKind: "userInput",
            rationale: "Choose one option.",
            options: [],
            rawPayloadSummary: nil
        )

        XCTAssertEqual(
            assistantPermissionCardState(
                for: request,
                pendingRequest: request,
                sessionStatus: .completed
            ),
            .waitingForInput
        )
    }

    func testCompletedSessionMarksOldRequestCompleted() {
        let request = AssistantPermissionRequest(
            id: 42,
            sessionID: "session-1",
            toolTitle: "browser_run_code",
            toolKind: "playwright",
            rationale: "Run code in the browser?",
            options: [],
            rawPayloadSummary: nil
        )

        XCTAssertEqual(
            assistantPermissionCardState(
                for: request,
                pendingRequest: nil,
                sessionStatus: .completed
            ),
            .completed
        )
    }

    func testNonActiveRequestDoesNotStayWaitingWhenSessionMovedOn() {
        let request = AssistantPermissionRequest(
            id: 42,
            sessionID: "session-1",
            toolTitle: "browser_click",
            toolKind: "playwright",
            rationale: "Allow the click?",
            options: [],
            rawPayloadSummary: nil
        )

        XCTAssertEqual(
            assistantPermissionCardState(
                for: request,
                pendingRequest: nil,
                sessionStatus: .active
            ),
            .notActive
        )
    }
}
