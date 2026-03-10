import XCTest
@testable import KeyScribe

final class AssistantModePolicyTests: XCTestCase {
    func testCommandSafetyClassifiesReadOnlyCommands() {
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "rg --files Sources"),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "sed -n '1,20p' README.md"),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "git diff --stat"),
            .readOnly
        )
    }

    func testCommandSafetyClassifiesValidationCommands() {
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "swift build"),
            .validation
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "swift test"),
            .validation
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "xcodebuild test -scheme KeyScribe"),
            .validation
        )
    }

    func testCommandSafetyClassifiesMutatingOrUnknownCommands() {
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "rm -rf tmp"),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "rg TODO Sources | head"),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "swift package update"),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "custom-tool --flag"),
            .mutatingOrUnknown
        )
    }

    func testModePolicyAllowsExpectedActivities() {
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .webSearch
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .commandExecution,
                command: "pwd"
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .commandExecution,
                command: "swift test"
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .commandExecution,
                command: "swift test"
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .fileChange
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .browserAutomation
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .dynamicToolCall,
                toolName: "computer_use"
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .browserAutomation
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .mcpToolCall
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .dynamicToolCall,
                toolName: "computer_use"
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .subagent
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .agentic,
                activityKind: .fileChange
            )
        )
    }
}
