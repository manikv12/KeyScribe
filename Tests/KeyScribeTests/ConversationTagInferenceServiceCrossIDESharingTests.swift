import XCTest
@testable import KeyScribe

final class ConversationTagInferenceServiceCrossIDESharingTests: XCTestCase {
    private let service = ConversationTagInferenceService.shared

    func testShouldShareCrossIDECodingContextWithMeaningfulProjectKey() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.apple.dt.xcode",
            appName: "Xcode",
            projectKey: "project:keyscribe",
            featureEnabled: true
        )

        XCTAssertTrue(result)
    }

    func testShouldNotShareCrossIDECodingContextWithUnknownProjectKey() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.apple.dt.xcode",
            appName: "Xcode",
            projectKey: "project:unknown",
            featureEnabled: true
        )

        XCTAssertFalse(result)
    }

    func testShouldNotShareCrossIDECodingContextWithAutomationFoldersPlaceholderProjectKey() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.apple.dt.xcode",
            appName: "Xcode",
            projectKey: "project:automation-folders",
            featureEnabled: true
        )

        XCTAssertFalse(result)
    }

    func testShouldNotShareCrossIDECodingContextWhenFeatureDisabled() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.apple.dt.xcode",
            appName: "Xcode",
            projectKey: "project:keyscribe",
            featureEnabled: false
        )

        XCTAssertFalse(result)
    }

    func testShouldNotShareCrossIDECodingContextForNonCodingApp() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            projectKey: "project:keyscribe",
            featureEnabled: true
        )

        XCTAssertFalse(result)
    }

    func testShouldSuppressUnknownCodingHistoryForUnknownCodingContext() {
        let result = service.shouldSuppressUnknownCodingHistory(
            bundleID: "com.openai.codex",
            appName: "Codex",
            projectKey: "project:unknown",
            identityKey: "identity:unknown"
        )

        XCTAssertTrue(result)
    }

    func testShouldNotSuppressUnknownCodingHistoryWhenIdentityIsMeaningful() {
        let result = service.shouldSuppressUnknownCodingHistory(
            bundleID: "com.openai.codex",
            appName: "Codex",
            projectKey: "project:unknown",
            identityKey: "thread:bug-123"
        )

        XCTAssertFalse(result)
    }

    func testShouldNotSuppressUnknownCodingHistoryWhenProjectIsMeaningful() {
        let result = service.shouldSuppressUnknownCodingHistory(
            bundleID: "com.openai.codex",
            appName: "Codex",
            projectKey: "project:keyscribe",
            identityKey: "identity:unknown"
        )

        XCTAssertFalse(result)
    }

    func testShouldNotSuppressUnknownCodingHistoryForNonCodingApp() {
        let result = service.shouldSuppressUnknownCodingHistory(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            projectKey: "project:unknown",
            identityKey: "identity:unknown"
        )

        XCTAssertFalse(result)
    }

    func testAppleMessagesInfersPersonIdentityFromScreenLabel() {
        let context = PromptRewriteConversationContext(
            id: "ctx-messages",
            appName: "Messages",
            bundleIdentifier: "com.apple.MobileSMS",
            screenLabel: "Scott Boy - Text Message • SMS",
            fieldLabel: "Message"
        )

        let tags = service.inferTags(capturedContext: context, userText: "")
        XCTAssertEqual(tags.identityType, "person")
        XCTAssertEqual(tags.identityLabel, "Scott Boy")
        XCTAssertEqual(tags.identityKey, "person:scott-boy")
    }

    func testAppleMessagesInfersPersonIdentityFromSimpleHeader() {
        let context = PromptRewriteConversationContext(
            id: "ctx-messages-2",
            appName: "Messages",
            bundleIdentifier: "com.apple.MobileSMS",
            screenLabel: "Scott",
            fieldLabel: "Message"
        )

        let tags = service.inferTags(capturedContext: context, userText: "")
        XCTAssertEqual(tags.identityType, "person")
        XCTAssertEqual(tags.identityLabel, "Scott")
        XCTAssertEqual(tags.identityKey, "person:scott")
    }

    func testAppleMessagesStripsMaybePrefixFromPersonName() {
        let context = PromptRewriteConversationContext(
            id: "ctx-messages-3",
            appName: "Messages",
            bundleIdentifier: "com.apple.MobileSMS",
            screenLabel: "Maybe: Contact Person - Text Message • SMS",
            fieldLabel: "Message"
        )

        let tags = service.inferTags(capturedContext: context, userText: "")
        XCTAssertEqual(tags.identityType, "person")
        XCTAssertEqual(tags.identityLabel, "Contact Person")
        XCTAssertEqual(tags.identityKey, "person:contact-person")
    }

    func testCodexTreatsAutomationFoldersLabelAsUnknownProject() {
        let context = PromptRewriteConversationContext(
            id: "ctx-codex-automation-folders",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Project: Automation folders | Thread: Fix portion selector confirm",
            fieldLabel: "Focused Input"
        )

        let tags = service.inferTags(capturedContext: context, userText: "")
        XCTAssertEqual(tags.projectLabel, "Unknown Project")
        XCTAssertEqual(tags.projectKey, "project:unknown")
    }

    func testCodexTreatsAutomationsCounterLabelAsUnknownProject() {
        let context = PromptRewriteConversationContext(
            id: "ctx-codex-automations-counter",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Project: Automations 1",
            fieldLabel: "Focused Input"
        )

        let tags = service.inferTags(capturedContext: context, userText: "")
        XCTAssertEqual(tags.projectLabel, "Unknown Project")
        XCTAssertEqual(tags.projectKey, "project:unknown")
    }

    func testCodexStillInfersRealProjectLabelFromContext() {
        let context = PromptRewriteConversationContext(
            id: "ctx-codex-spike",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Project: Spike | Thread: Fix portion selector confirm",
            fieldLabel: "Focused Input"
        )

        let tags = service.inferTags(capturedContext: context, userText: "")
        XCTAssertEqual(tags.projectLabel, "Spike")
        XCTAssertEqual(tags.projectKey, "project:spike")
    }
}
