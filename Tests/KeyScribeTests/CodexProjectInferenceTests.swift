import XCTest
@testable import KeyScribe

final class CodexProjectInferenceTests: XCTestCase {
    func testCodexControlLabelExtractsProjectFromStartNewThreadLabel() {
        let project = PromptRewriteConversationContextResolver.codexProjectFromControlLabel(
            "Start new thread in KeyScribe",
            includeProjectSectionLabels: true
        )

        XCTAssertEqual(project, "KeyScribe")
    }

    func testCodexTopBarCandidateRejectsOpenInPopoutWindow() {
        let project = PromptRewriteConversationContextResolver.codexNormalizedTopBarProjectCandidate(
            "Open in Popout Window"
        )

        XCTAssertNil(project)
    }

    func testCodexTrustedProjectCandidateRequiresTrustedSignal() {
        let project = PromptRewriteConversationContextResolver.codexTrustedProjectCandidate(
            topBarProject: nil,
            sidebarProject: nil
        )

        XCTAssertNil(project)
    }

    func testCodexTrustedProjectCandidatePrefersVisibleSelectionOverTopBar() {
        let project = PromptRewriteConversationContextResolver.codexTrustedProjectCandidate(
            visualProject: "Project Vellum",
            topBarProject: "KeyScribe",
            sidebarProject: "Project Vellum"
        )

        XCTAssertEqual(project, "Project Vellum")
    }

    func testCodexTrustedProjectCandidateUsesTopBarWhenNoVisibleProjectExists() {
        let project = PromptRewriteConversationContextResolver.codexTrustedProjectCandidate(
            visualProject: nil,
            topBarProject: "KeyScribe",
            sidebarProject: nil
        )

        XCTAssertEqual(project, "KeyScribe")
    }

    func testCodexTrustedProjectCandidateUsesVisualProjectWhenTopBarMissing() {
        let project = PromptRewriteConversationContextResolver.codexTrustedProjectCandidate(
            visualProject: "KeyScribe",
            topBarProject: nil,
            sidebarProject: "Project Vellum"
        )

        XCTAssertEqual(project, "KeyScribe")
    }

    func testCodexMainContentScreenshotExtractsProjectFromLetsBuildPair() {
        let observations = [
            PromptRewriteConversationContextResolver.CodexVisualTextObservationCandidate(
                text: "Let's build",
                bounds: CGRect(x: 780, y: 820, width: 220, height: 52)
            ),
            PromptRewriteConversationContextResolver.CodexVisualTextObservationCandidate(
                text: "KeyScribe",
                bounds: CGRect(x: 760, y: 878, width: 240, height: 58)
            )
        ]

        let project = PromptRewriteConversationContextResolver.codexMainContentProjectFromScreenshot(
            observations,
            imageSize: CGSize(width: 1400, height: 1800)
        )

        XCTAssertEqual(project, "KeyScribe")
    }

    func testCodexMainContentScreenshotDoesNotTreatChatTextAsProject() {
        let observations = [
            PromptRewriteConversationContextResolver.CodexVisualTextObservationCandidate(
                text: "Can you fix this issue in the HUD?",
                bounds: CGRect(x: 780, y: 1320, width: 480, height: 42)
            ),
            PromptRewriteConversationContextResolver.CodexVisualTextObservationCandidate(
                text: "What happenes if user is inside chat ?",
                bounds: CGRect(x: 760, y: 1560, width: 540, height: 38)
            )
        ]

        let project = PromptRewriteConversationContextResolver.codexMainContentProjectFromScreenshot(
            observations,
            imageSize: CGSize(width: 1400, height: 1800)
        )

        XCTAssertNil(project)
    }

    func testCodexActionLabelsAreTreatedAsUnknownProjects() {
        XCTAssertTrue(
            PromptRewriteConversationContextResolver.shouldTreatCodexProjectLabelAsUnknown("Hand off")
        )
        XCTAssertTrue(
            PromptRewriteConversationContextResolver.shouldTreatCodexProjectLabelAsUnknown("Run")
        )
        XCTAssertTrue(
            PromptRewriteConversationContextResolver.shouldTreatCodexProjectLabelAsUnknown("Automations 1")
        )
        XCTAssertTrue(
            PromptRewriteConversationContextResolver.shouldTreatCodexProjectLabelAsUnknown("Worked for 6m 40s")
        )
        XCTAssertTrue(
            PromptRewriteConversationContextResolver.shouldTreatCodexProjectLabelAsUnknown("User attachment")
        )
        XCTAssertTrue(
            PromptRewriteConversationContextResolver.shouldTreatCodexProjectLabelAsUnknown("Undo")
        )
        XCTAssertTrue(
            PromptRewriteConversationContextResolver.shouldTreatCodexProjectLabelAsUnknown("Edit message")
        )
        XCTAssertFalse(
            PromptRewriteConversationContextResolver.shouldTreatCodexProjectLabelAsUnknown("KeyScribe")
        )
    }

    func testCodexSanitizedScreenLabelKeepsThreadWhenProjectIsBogus() {
        let sanitized = PromptRewriteConversationContextResolver.sanitizedCodexScreenLabel(
            "Project: Open in Popout Window | Thread: Diagnose Codex project lookup"
        )

        XCTAssertEqual(sanitized, "Thread: Diagnose Codex project lookup")
    }

    func testDisplayNameOmitsGenericIdentityAndFieldLabels() {
        let context = PromptRewriteConversationContext(
            id: "ctx-codex-generic",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Current Screen",
            fieldLabel: "Focused Input",
            projectKey: "project:unknown",
            projectLabel: "Unknown Project",
            identityKey: "identity:unknown",
            identityType: "unknown",
            identityLabel: "Unknown Identity"
        )

        XCTAssertEqual(context.displayName, "Codex")
    }
}
