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
}
