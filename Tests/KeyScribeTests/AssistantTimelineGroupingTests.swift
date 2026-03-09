import XCTest
@testable import KeyScribe

final class AssistantTimelineGroupingTests: XCTestCase {
    func testConsecutiveActivitiesBecomeOneGroupedRenderItem() {
        let startedAt = Date(timeIntervalSince1970: 1_741_400_000)
        let items: [AssistantTimelineItem] = [
            .assistantProgress(
                id: "progress-1",
                sessionID: "session-1",
                text: "I am checking the files now.",
                createdAt: startedAt,
                updatedAt: startedAt,
                isStreaming: false,
                source: .runtime
            ),
            .activity(
                AssistantActivityItem(
                    id: "command-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    kind: .commandExecution,
                    title: "Command",
                    status: .completed,
                    friendlySummary: "Ran a terminal command.",
                    rawDetails: "rg --files",
                    startedAt: startedAt.addingTimeInterval(1),
                    updatedAt: startedAt.addingTimeInterval(1),
                    source: .runtime
                )
            ),
            .activity(
                AssistantActivityItem(
                    id: "search-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    kind: .webSearch,
                    title: "Web Search",
                    status: .completed,
                    friendlySummary: "Searched the web.",
                    rawDetails: "codex app server timeline ui",
                    startedAt: startedAt.addingTimeInterval(2),
                    updatedAt: startedAt.addingTimeInterval(2),
                    source: .runtime
                )
            ),
            .assistantFinal(
                id: "final-1",
                sessionID: "session-1",
                text: "I found the renderer and the event path.",
                createdAt: startedAt.addingTimeInterval(3),
                updatedAt: startedAt.addingTimeInterval(3),
                isStreaming: false,
                source: .runtime
            )
        ]

        let renderItems = buildAssistantTimelineRenderItems(from: items)

        XCTAssertEqual(renderItems.count, 3)
        XCTAssertEqual(renderItems[0].id, "progress-1")
        XCTAssertEqual(renderItems[2].id, "final-1")

        guard case .activityGroup(let group) = renderItems[1] else {
            return XCTFail("Expected the middle render item to be an activity group.")
        }

        XCTAssertEqual(group.activities.count, 2)
        XCTAssertEqual(group.activities.map(\.id), ["command-1", "search-1"])
    }

    func testSingleActivityStaysAsSingleRenderItem() {
        let startedAt = Date(timeIntervalSince1970: 1_741_400_100)
        let items: [AssistantTimelineItem] = [
            .activity(
                AssistantActivityItem(
                    id: "command-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    kind: .commandExecution,
                    title: "Command",
                    status: .completed,
                    friendlySummary: "Ran a terminal command.",
                    rawDetails: "pwd",
                    startedAt: startedAt,
                    updatedAt: startedAt,
                    source: .runtime
                )
            )
        ]

        let renderItems = buildAssistantTimelineRenderItems(from: items)

        XCTAssertEqual(renderItems.count, 1)
        guard case .timeline(let item) = renderItems[0] else {
            return XCTFail("Expected a single activity to stay ungrouped.")
        }
        XCTAssertEqual(item.id, "command-1")
    }

    func testVisibleWindowKeepsNewestRenderItems() {
        let baseDate = Date(timeIntervalSince1970: 1_741_400_200)
        let items = (0..<5).map { index in
            AssistantTimelineItem.assistantFinal(
                id: "final-\(index)",
                sessionID: "session-1",
                text: "Message \(index)",
                createdAt: baseDate.addingTimeInterval(TimeInterval(index)),
                updatedAt: baseDate.addingTimeInterval(TimeInterval(index)),
                isStreaming: false,
                source: .runtime
            )
        }

        let renderItems = buildAssistantTimelineRenderItems(from: items)
        let visibleWindow = assistantTimelineVisibleWindow(from: renderItems, visibleLimit: 2)

        XCTAssertEqual(visibleWindow.count, 2)
        XCTAssertEqual(visibleWindow.map(\.id), ["final-3", "final-4"])
    }

    func testNextVisibleLimitLoadsOlderHistoryInBatchesAndClamps() {
        XCTAssertEqual(
            assistantTimelineNextVisibleLimit(
                currentLimit: 48,
                totalCount: 70,
                batchSize: 24
            ),
            70
        )

        XCTAssertEqual(
            assistantTimelineNextVisibleLimit(
                currentLimit: 12,
                totalCount: 100,
                batchSize: 24
            ),
            36
        )
    }
}
