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
}
