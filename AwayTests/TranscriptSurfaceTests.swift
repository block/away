import XCTest
@testable import Away
#if os(iOS)
import UIKit
#endif

final class TranscriptSurfaceTests: XCTestCase {
    func testRowsHideEmptyLoadingSessionUntilTranscriptRowsAreReady() {
        let session = SessionSummary(id: "s1", title: "Large Session", messageCount: 4_000)

        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: [],
            isLoading: true,
            hasAuthoritativeReplay: false,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows, [])
    }

    func testRowsHideProvisionalSnapshotWhileLoading() {
        let session = SessionSummary(id: "s1", title: "Large Session", messageCount: 4_000)
        let messages = [
            ChatMessage(id: "snapshot-1", role: .assistant, content: [.text("Provisional tail")])
        ]

        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: messages,
            isLoading: true,
            hasAuthoritativeReplay: false,
            snapshotMessageIDs: ["snapshot-1"],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows, [])
    }

    func testRowsKeepOptimisticMessagesVisibleWhileSnapshotIsLoading() {
        let session = SessionSummary(id: "s1", title: "Large Session", messageCount: 4_000)
        let snapshot = ChatMessage(id: "snapshot-1", role: .assistant, content: [.text("Provisional tail")])
        let optimistic = ChatMessage(id: "local-1", role: .user, content: [.text("Queued prompt")])

        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: [snapshot, optimistic],
            isLoading: true,
            hasAuthoritativeReplay: false,
            snapshotMessageIDs: ["snapshot-1"],
            optimisticUserMessageIDs: ["local-1"]
        )

        XCTAssertEqual(rows, [.message(optimistic)])
    }

    func testRowsShowSnapshotAfterLoadingCompletes() {
        let session = SessionSummary(id: "s1", title: "Large Session", messageCount: 4_000)
        let snapshot = ChatMessage(id: "snapshot-1", role: .assistant, content: [.text("Fallback tail")])

        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: [snapshot],
            isLoading: false,
            hasAuthoritativeReplay: false,
            snapshotMessageIDs: ["snapshot-1"],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows, [.message(snapshot)])
    }

    func testRowsExposeAllFetchedMessagesToPlatformAdapter() {
        let messages = makeMessages(count: 5_000)

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: messages,
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows.count, 5_000)
        XCTAssertEqual(rows.first?.id, "message:message-0")
        XCTAssertEqual(rows.last?.id, "message:message-4999")
    }

    func testRowsSplitLongAssistantTextIntoStableChunks() {
        let longText = String(repeating: "Large assistant transcript paragraph with enough text to require chunking. ", count: 180)
        let message = ChatMessage(id: "assistant-1", role: .assistant, content: [.text(longText)])

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "message:assistant-1")
        XCTAssertEqual(rows.dropFirst().first?.id, "message:assistant-1::chunk:1")
        let chunkedText = rows.compactMap { row -> String? in
            guard case .message(let message) = row,
                  case .text(let text) = message.content.first
            else {
                return nil
            }
            return text
        }
        XCTAssertEqual(chunkedText.joined(), longText)
        XCTAssertTrue(chunkedText.dropLast().allSatisfy { $0.count <= TranscriptTextChunker.defaultCharacterLimit + 1 })
    }

    func testRowsKeepLongUserTextAsSingleBubble() {
        let longText = String(repeating: "Large user prompt. ", count: 260)
        let message = ChatMessage(id: "user-1", role: .user, content: [.text(longText)])

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows, [.message(message)])
    }

    func testRowsAppendAssistantProgressAfterOptimisticUserWhenAwaitingResponse() {
        let existing = ChatMessage(id: "assistant-1", role: .assistant, content: [.text("Ready")])
        let optimistic = ChatMessage(id: "local-user", role: .user, content: [.text("Hello")])

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [existing, optimistic],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: ["local-user"],
            showsAssistantProgress: true
        )

        XCTAssertEqual(
            rows,
            [
                .message(existing),
                .message(optimistic),
                .assistantProgress(anchorMessageID: "local-user")
            ]
        )
    }

    func testBottomScrollPolicyRequestsOnlyWhenSettledAndNearBottom() {
        XCTAssertTrue(
            TranscriptBottomScrollPolicy.shouldRequestAfterInitialSettle(canSettleToBottom: true)
        )
        XCTAssertFalse(
            TranscriptBottomScrollPolicy.shouldRequestAfterInitialSettle(canSettleToBottom: false)
        )
        XCTAssertTrue(
            TranscriptBottomScrollPolicy.shouldRequestAfterMessageCountChanged(
                canSettleToBottom: true,
                isUserNearBottom: false,
                oldCount: 0
            )
        )
        XCTAssertTrue(
            TranscriptBottomScrollPolicy.shouldRequestAfterMessageCountChanged(
                canSettleToBottom: true,
                isUserNearBottom: true,
                oldCount: 12
            )
        )
        XCTAssertFalse(
            TranscriptBottomScrollPolicy.shouldRequestAfterMessageCountChanged(
                canSettleToBottom: true,
                isUserNearBottom: false,
                oldCount: 12
            )
        )
        XCTAssertFalse(
            TranscriptBottomScrollPolicy.shouldRequestAfterLastMessageChanged(
                canSettleToBottom: true,
                isUserNearBottom: false
            )
        )
    }

    func testAssistantProgressPolicyShowsOnlyForAwaitingOptimisticUserPrompt() {
        let existing = ChatMessage(id: "assistant-1", role: .assistant, content: [.text("Ready")])
        let optimistic = ChatMessage(id: "local-user", role: .user, content: [.text("Hello")])

        XCTAssertTrue(
            TranscriptAssistantProgressPolicy.shouldShow(
                messages: [existing, optimistic],
                optimisticUserMessageIDs: ["local-user"],
                isLoading: false,
                queuedPromptCount: 0,
                errorMessage: nil
            )
        )
        XCTAssertFalse(
            TranscriptAssistantProgressPolicy.shouldShow(
                messages: [existing, optimistic],
                optimisticUserMessageIDs: ["local-user"],
                isLoading: true,
                queuedPromptCount: 0,
                errorMessage: nil
            )
        )
        XCTAssertFalse(
            TranscriptAssistantProgressPolicy.shouldShow(
                messages: [existing, optimistic],
                optimisticUserMessageIDs: ["local-user"],
                isLoading: false,
                queuedPromptCount: 1,
                errorMessage: nil
            )
        )
        XCTAssertFalse(
            TranscriptAssistantProgressPolicy.shouldShow(
                messages: [],
                optimisticUserMessageIDs: ["local-user"],
                isLoading: false,
                queuedPromptCount: 0,
                errorMessage: nil
            )
        )
        XCTAssertFalse(
            TranscriptAssistantProgressPolicy.shouldShow(
                messages: [existing, optimistic],
                optimisticUserMessageIDs: ["local-user"],
                isLoading: false,
                queuedPromptCount: 0,
                errorMessage: "Failed"
            )
        )
        XCTAssertFalse(
            TranscriptAssistantProgressPolicy.shouldShow(
                messages: [existing, optimistic, existing],
                optimisticUserMessageIDs: ["local-user"],
                isLoading: false,
                queuedPromptCount: 0,
                errorMessage: nil
            )
        )
    }

    func testComposerShowsSteeringLabelOnlyWhenDraftHasText() {
        XCTAssertFalse(
            ComposerStatusPolicy.shouldShowSteeringLabel(
                isSteering: true,
                draftText: ""
            )
        )
        XCTAssertFalse(
            ComposerStatusPolicy.shouldShowSteeringLabel(
                isSteering: true,
                draftText: " \n\t "
            )
        )
        XCTAssertFalse(
            ComposerStatusPolicy.shouldShowSteeringLabel(
                isSteering: false,
                draftText: "steer this run"
            )
        )
        XCTAssertTrue(
            ComposerStatusPolicy.shouldShowSteeringLabel(
                isSteering: true,
                draftText: "steer this run"
            )
        )
    }

    func testAnimationPolicyRecognizesOptimisticUserInsertionOnlyAtFollowedBottom() {
        let oldRows = [
            TranscriptSurfaceRow.message(ChatMessage(id: "assistant-1", role: .assistant, content: [.text("Ready")]))
        ]
        let optimisticUser = ChatMessage(id: "local-user", role: .user, content: [.text("Hello")])
        let newRows = oldRows + [.message(optimisticUser)]

        XCTAssertEqual(
            TranscriptAnimationPolicy.rowChange(oldRows: oldRows, newRows: newRows),
            .tailAppend(startIndex: 1, count: 1)
        )
        XCTAssertEqual(
            TranscriptAnimationPolicy.bottomEntranceInsertedRowIDs(
                oldRows: oldRows,
                newRows: newRows,
                optimisticUserMessageIDs: ["local-user"],
                wasNearBottom: true
            ),
            ["message:local-user"]
        )
        XCTAssertEqual(
            TranscriptAnimationPolicy.bottomEntranceInsertedRowIDs(
                oldRows: oldRows,
                newRows: newRows,
                optimisticUserMessageIDs: ["local-user"],
                wasNearBottom: false
            ),
            []
        )
        XCTAssertEqual(
            TranscriptAnimationPolicy.bottomEntranceInsertedRowIDs(
                oldRows: oldRows,
                newRows: newRows,
                optimisticUserMessageIDs: [],
                wasNearBottom: true
            ),
            []
        )
    }

    func testAnimationPolicyBottomEntranceIncludesOptimisticUserProgressAndToolRows() {
        let oldRows = [
            TranscriptSurfaceRow.message(ChatMessage(id: "assistant-1", role: .assistant, content: [.text("Ready")]))
        ]
        let optimisticUser = ChatMessage(id: "local-user", role: .user, content: [.text("Hello")])
        let toolMessage = ChatMessage(
            id: "assistant-tool",
            role: .assistant,
            content: [.tool(ToolActivity(id: "tool-1", name: "shell", status: "in_progress"))],
            isStreaming: true
        )

        XCTAssertEqual(
            TranscriptAnimationPolicy.bottomEntranceInsertedRowIDs(
                oldRows: oldRows,
                newRows: oldRows + [
                    .message(optimisticUser),
                    .assistantProgress(anchorMessageID: "local-user")
                ],
                optimisticUserMessageIDs: ["local-user"],
                wasNearBottom: true
            ),
            [
                "message:local-user",
                "assistant-progress:local-user"
            ]
        )
        XCTAssertEqual(
            TranscriptAnimationPolicy.bottomEntranceInsertedRowIDs(
                oldRows: oldRows,
                newRows: oldRows + [.message(toolMessage)],
                optimisticUserMessageIDs: [],
                wasNearBottom: true
            ),
            ["message:assistant-tool"]
        )
        XCTAssertEqual(
            TranscriptAnimationPolicy.bottomEntranceInsertedRowIDs(
                oldRows: oldRows,
                newRows: oldRows + [.message(toolMessage)],
                optimisticUserMessageIDs: [],
                wasNearBottom: false
            ),
            []
        )
    }

    func testAnimationPolicyDoesNotAnimateHistoricalToolRowsOnInitialOpen() {
        let historicalToolRows = [
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "assistant-tool",
                    role: .assistant,
                    content: [.tool(ToolActivity(id: "tool-1", name: "shell", status: "completed"))]
                )
            )
        ]

        XCTAssertEqual(
            TranscriptAnimationPolicy.bottomEntranceInsertedRowIDs(
                oldRows: [],
                newRows: historicalToolRows,
                optimisticUserMessageIDs: [],
                wasNearBottom: true
            ),
            []
        )
    }

    func testAnimationPolicyTreatsProgressReplacementAsBottomEntrance() {
        let oldRows = [
            TranscriptSurfaceRow.message(ChatMessage(id: "local-user", role: .user, content: [.text("Hello")])),
            TranscriptSurfaceRow.assistantProgress(anchorMessageID: "local-user")
        ]
        let assistant = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [.text("Starting")],
            isStreaming: true
        )
        let newRows = [
            TranscriptSurfaceRow.message(ChatMessage(id: "local-user", role: .user, content: [.text("Hello")])),
            TranscriptSurfaceRow.message(assistant)
        ]

        XCTAssertEqual(
            TranscriptAnimationPolicy.rowChange(oldRows: oldRows, newRows: newRows),
            .tailReplacement(startIndex: 1, deletedCount: 1, insertedCount: 1)
        )
        XCTAssertEqual(
            TranscriptAnimationPolicy.bottomEntranceInsertedRowIDs(
                oldRows: oldRows,
                newRows: newRows,
                optimisticUserMessageIDs: ["local-user"],
                wasNearBottom: true
            ),
            []
        )
        XCTAssertTrue(
            TranscriptAnimationPolicy.shouldAnimateStreamingBottomFollow(
                oldRows: oldRows,
                newRows: newRows,
                isLoading: false,
                wasNearBottom: true
            )
        )
    }

    func testAnimationPolicyFindsNewInlineToolContentIDs() {
        let oldRows = [
            TranscriptSurfaceRow.message(
                ChatMessage(id: "assistant-1", role: .assistant, content: [.text("I will run a tool")], isStreaming: true)
            )
        ]
        let newRows = [
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "assistant-1",
                    role: .assistant,
                    content: [
                        .text("I will run a tool"),
                        .tool(ToolActivity(id: "tool-1", name: "shell", status: "in_progress"))
                    ],
                    isStreaming: true
                )
            )
        ]

        XCTAssertEqual(
            TranscriptAnimationPolicy.newToolContentIDsByRowID(
                oldRows: oldRows,
                newRows: newRows,
                wasNearBottom: true
            ),
            ["message:assistant-1": ["tool:tool-1"]]
        )
        XCTAssertEqual(
            TranscriptAnimationPolicy.newToolContentIDsByRowID(
                oldRows: oldRows,
                newRows: newRows,
                wasNearBottom: false
            ),
            [:]
        )
    }

    func testAnimationPolicyAnimatesStreamingBottomFollowForGrowthButNotReplayOrScrolledAway() {
        let oldRows = [
            TranscriptSurfaceRow.message(
                ChatMessage(id: "assistant-1", role: .assistant, content: [.text("A short line")], isStreaming: true)
            )
        ]
        let grownRows = [
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "assistant-1",
                    role: .assistant,
                    content: [.text("A short line\nA second line that increases height")],
                    isStreaming: true
                )
            )
        ]

        XCTAssertTrue(
            TranscriptAnimationPolicy.shouldAnimateStreamingBottomFollow(
                oldRows: oldRows,
                newRows: grownRows,
                isLoading: false,
                wasNearBottom: true
            )
        )
        XCTAssertFalse(
            TranscriptAnimationPolicy.shouldAnimateStreamingBottomFollow(
                oldRows: oldRows,
                newRows: grownRows,
                isLoading: false,
                wasNearBottom: false
            )
        )
        XCTAssertFalse(
            TranscriptAnimationPolicy.shouldAnimateStreamingBottomFollow(
                oldRows: oldRows,
                newRows: grownRows,
                isLoading: true,
                wasNearBottom: true
            )
        )
        XCTAssertFalse(
            TranscriptAnimationPolicy.shouldAnimateStreamingBottomFollow(
                oldRows: grownRows,
                newRows: grownRows,
                isLoading: false,
                wasNearBottom: true
            )
        )
        XCTAssertFalse(
            TranscriptAnimationPolicy.shouldAnimateStreamingBottomFollow(
                oldRows: grownRows,
                newRows: oldRows + [
                    .message(ChatMessage(id: "earlier", role: .assistant, content: [.text("Reordered")]))
                ],
                isLoading: false,
                wasNearBottom: true
            )
        )

        let nonTailStreamingRows = [
            TranscriptSurfaceRow.message(
                ChatMessage(id: "inserted-before-stream", role: .assistant, content: [.text("Inserted above")])
            ),
            grownRows[0]
        ]
        XCTAssertEqual(
            TranscriptAnimationPolicy.rowChange(oldRows: grownRows, newRows: nonTailStreamingRows),
            .nonTailChange
        )
        XCTAssertFalse(
            TranscriptAnimationPolicy.shouldAnimateStreamingBottomFollow(
                oldRows: grownRows,
                newRows: nonTailStreamingRows,
                isLoading: false,
                wasNearBottom: true
            )
        )
    }

    func testAnimationPolicyTreatsNewOversizedStreamingChunkAsTailAppend() {
        let oldText = String(repeating: "streaming text ", count: 150)
        let newText = oldText + String(repeating: "additional streamed text ", count: 80)
        let oldRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [
                ChatMessage(id: "assistant-1", role: .assistant, content: [.text(oldText)], isStreaming: true)
            ],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let newRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [
                ChatMessage(id: "assistant-1", role: .assistant, content: [.text(newText)], isStreaming: true)
            ],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(oldRows.first?.id, "message:assistant-1")
        XCTAssertEqual(newRows.first?.id, "message:assistant-1")
        XCTAssertEqual(
            TranscriptAnimationPolicy.rowChange(oldRows: oldRows, newRows: newRows),
            .tailAppend(startIndex: oldRows.count, count: newRows.count - oldRows.count)
        )
        XCTAssertTrue(
            TranscriptAnimationPolicy.shouldAnimateStreamingBottomFollow(
                oldRows: oldRows,
                newRows: newRows,
                isLoading: false,
                wasNearBottom: true
            )
        )
    }

    #if os(iOS)
    @MainActor
    func testTableViewHostsOnlyVisibleCellsForLargeSyntheticTranscript() throws {
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 5_000),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let dataSource = TranscriptTableViewDataSource()
        dataSource.rows = rows
        let delegate = NoOpTableDelegate()

        let tableView = TranscriptTableViewFactory.make(dataSource: dataSource, delegate: delegate)
        let window = try host(tableView)

        tableView.reloadData()
        tableView.layoutIfNeeded()

        XCTAssertEqual(dataSource.rows.count, 5_000)
        XCTAssertGreaterThan(tableView.visibleCells.count, 0)
        XCTAssertLessThan(tableView.visibleCells.count, 30)
        XCTAssertLessThan(dataSource.createdCellCount, 60)
        _ = window
    }

    func testEstimatedRowHeightScalesForLongAssistantMessages() {
        let shortRow = TranscriptSurfaceRow.message(
            ChatMessage(id: "short", role: .assistant, content: [.text("Short response.")])
        )
        let longRow = TranscriptSurfaceRow.message(
            ChatMessage(
                id: "long",
                role: .assistant,
                content: [.text(String(repeating: "Long transcript response with enough words to wrap across many lines. ", count: 420))]
            )
        )

        let shortHeight = TranscriptRowHeightEstimator.estimatedHeight(for: shortRow, tableWidth: 390)
        let longHeight = TranscriptRowHeightEstimator.estimatedHeight(for: longRow, tableWidth: 390)

        XCTAssertLessThan(shortHeight, 80)
        XCTAssertGreaterThan(longHeight, 1_000)
        XCTAssertGreaterThan(longHeight, shortHeight * 15)
    }

    func testEstimatedRowHeightAccountsForUserBubbleWidth() {
        let text = String(repeating: "Wrapping text. ", count: 120)
        let assistantRow = TranscriptSurfaceRow.message(
            ChatMessage(id: "assistant", role: .assistant, content: [.text(text)])
        )
        let userRow = TranscriptSurfaceRow.message(
            ChatMessage(id: "user", role: .user, content: [.text(text)])
        )

        let assistantHeight = TranscriptRowHeightEstimator.estimatedHeight(for: assistantRow, tableWidth: 390)
        let userHeight = TranscriptRowHeightEstimator.estimatedHeight(for: userRow, tableWidth: 390)

        XCTAssertGreaterThan(userHeight, assistantHeight)
    }

    @MainActor
    func testCoordinatorHidesOversizedInitialTranscriptUntilBottomSettles() throws {
        let harness = try makeCoordinatorHarness()
        let rows = [
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "long",
                    role: .assistant,
                    content: [.text(String(repeating: "Large transcript row that should land pinned to the bottom after sizing. ", count: 520))]
                )
            )
        ]

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            isLoading: true,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )

        XCTAssertEqual(harness.tableView.alpha, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        harness.tableView.layoutIfNeeded()

        XCTAssertEqual(harness.tableView.alpha, 1)
        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)
    }

    @MainActor
    func testCoordinatorDoesNotHideShortInitialTranscript() throws {
        let harness = try makeCoordinatorHarness()
        let rows = [
            TranscriptSurfaceRow.message(
                ChatMessage(id: "short", role: .assistant, content: [.text("Short transcript.")])
            )
        ]

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            isLoading: true,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )

        XCTAssertEqual(harness.tableView.alpha, 1)
    }

    @MainActor
    func testCoordinatorScrollsToBottomInitiallyAndAfterAppendWhenNearBottom() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)

        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)

        let appendedRows = rows + [
            .message(
                ChatMessage(
                    id: "message-80",
                    role: .assistant,
                    createdAt: Date(timeIntervalSince1970: 80),
                    content: [.text("Newest assistant response")]
                )
            )
        ]
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: appendedRows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 2)
        )
        pumpLayout(for: harness.tableView)

        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)
        XCTAssertTrue(
            harness.tableView.indexPathsForVisibleRows?.contains(IndexPath(row: appendedRows.count - 1, section: 0)) == true
        )
    }

    @MainActor
    func testCoordinatorRendersInitialOptimisticUserWithoutInitialInsertBatch() throws {
        let harness = try makeCoordinatorHarness()
        let optimisticUser = ChatMessage(id: "local-user", role: .user, content: [.text("Hello")])
        let rows = [
            TranscriptSurfaceRow.message(optimisticUser),
            TranscriptSurfaceRow.assistantProgress(anchorMessageID: optimisticUser.id)
        ]

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            optimisticUserMessageIDs: [optimisticUser.id],
            earlierMessageCount: 0,
            scrollIntent: nil
        )
        pumpLayout(for: harness.tableView)

        XCTAssertEqual(harness.coordinator.dataSource.rows, rows)
        XCTAssertEqual(harness.tableView.numberOfRows(inSection: 0), rows.count)
        XCTAssertTrue(
            harness.tableView.indexPathsForVisibleRows?.contains(IndexPath(row: rows.count - 1, section: 0)) == true
        )
    }

    @MainActor
    func testCoordinatorReplacesAssistantProgressTailWithStreamingAssistant() throws {
        let harness = try makeCoordinatorHarness()
        let optimisticUser = ChatMessage(id: "local-user", role: .user, content: [.text("Hello")])
        let progressRows = [
            TranscriptSurfaceRow.message(optimisticUser),
            TranscriptSurfaceRow.assistantProgress(anchorMessageID: optimisticUser.id)
        ]

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: progressRows,
            optimisticUserMessageIDs: [optimisticUser.id],
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)

        let assistant = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [.text("Starting the response")],
            isStreaming: true
        )
        let replacementRows = [
            TranscriptSurfaceRow.message(optimisticUser),
            TranscriptSurfaceRow.message(assistant)
        ]
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: replacementRows,
            optimisticUserMessageIDs: [optimisticUser.id],
            earlierMessageCount: 0,
            scrollIntent: nil
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        harness.tableView.layoutIfNeeded()

        XCTAssertEqual(harness.coordinator.dataSource.rows, replacementRows)
        XCTAssertEqual(harness.tableView.numberOfRows(inSection: 0), replacementRows.count)
        XCTAssertTrue(
            harness.tableView.indexPathsForVisibleRows?.contains(IndexPath(row: replacementRows.count - 1, section: 0)) == true
        )
    }

    @MainActor
    func testCoordinatorPreservesAnchorWhenProgressTailReplacedWhileScrolledAway() throws {
        let harness = try makeCoordinatorHarness()
        let earlierRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let optimisticUser = ChatMessage(id: "local-user", role: .user, content: [.text("Hello")])
        let progressRows = earlierRows + [
            TranscriptSurfaceRow.message(optimisticUser),
            TranscriptSurfaceRow.assistantProgress(anchorMessageID: optimisticUser.id)
        ]

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: progressRows,
            optimisticUserMessageIDs: [optimisticUser.id],
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        harness.tableView.scrollToRow(at: IndexPath(row: 30, section: 0), at: .top, animated: false)
        harness.tableView.layoutIfNeeded()

        let anchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let anchoredRowID = progressRows[anchoredIndexPath.row].id
        let anchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: anchoredIndexPath).minY

        let assistant = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [.text("Starting the response")],
            isStreaming: true
        )
        let replacementRows = earlierRows + [
            TranscriptSurfaceRow.message(optimisticUser),
            TranscriptSurfaceRow.message(assistant)
        ]
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: replacementRows,
            optimisticUserMessageIDs: [optimisticUser.id],
            earlierMessageCount: 0,
            scrollIntent: nil
        )
        pumpLayout(for: harness.tableView)

        let newAnchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let newAnchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: newAnchoredIndexPath).minY
        XCTAssertEqual(replacementRows[newAnchoredIndexPath.row].id, anchoredRowID)
        XCTAssertLessThan(abs(newAnchoredOffset - anchoredOffset), 2)
        XCTAssertGreaterThan(distanceFromBottom(harness.tableView), 170)
    }

    @MainActor
    func testCoordinatorContinuesFollowingRapidStreamingGrowthBeforeScrollAnimationSettles() throws {
        let harness = try makeCoordinatorHarness()
        let user = ChatMessage(id: "local-user", role: .user, content: [.text("Reply with 15 paragraphs")])
        let initialRows = [
            TranscriptSurfaceRow.message(user),
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "assistant-1",
                    role: .assistant,
                    content: [.text("Paragraph 1.")],
                    isStreaming: true
                )
            )
        ]

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: initialRows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)

        let firstGrowthRows = [
            TranscriptSurfaceRow.message(user),
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "assistant-1",
                    role: .assistant,
                    content: [.text(paragraphText(count: 9))],
                    isStreaming: true
                )
            )
        ]
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: firstGrowthRows,
            earlierMessageCount: 0,
            scrollIntent: nil
        )

        XCTAssertGreaterThan(distanceFromBottom(harness.tableView), 170)

        let secondGrowthRows = [
            TranscriptSurfaceRow.message(user),
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "assistant-1",
                    role: .assistant,
                    content: [.text(paragraphText(count: 15))],
                    isStreaming: true
                )
            )
        ]
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: secondGrowthRows,
            earlierMessageCount: 0,
            scrollIntent: nil
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        harness.tableView.layoutIfNeeded()

        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)
        XCTAssertTrue(
            harness.tableView.indexPathsForVisibleRows?.contains(IndexPath(row: secondGrowthRows.count - 1, section: 0)) == true
        )
    }

    @MainActor
    func testCoordinatorContinuesFollowingDelayedStreamingContentSizeGrowth() throws {
        let harness = try makeCoordinatorHarness()
        let user = ChatMessage(id: "local-user", role: .user, content: [.text("Reply with 15 paragraphs")])
        let initialRows = [
            TranscriptSurfaceRow.message(user),
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "assistant-1",
                    role: .assistant,
                    content: [.text("Paragraph 1.")],
                    isStreaming: true
                )
            )
        ]

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: initialRows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)

        let streamingRows = [
            TranscriptSurfaceRow.message(user),
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "assistant-1",
                    role: .assistant,
                    content: [.text(paragraphText(count: 4))],
                    isStreaming: true
                )
            )
        ]
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: streamingRows,
            earlierMessageCount: 0,
            scrollIntent: nil
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        harness.tableView.layoutIfNeeded()

        let settledSize = harness.tableView.contentSize
        let oldDelayedSize = CGSize(
            width: settledSize.width,
            height: settledSize.height + 360
        )
        let newDelayedSize = CGSize(
            width: settledSize.width,
            height: oldDelayedSize.height + 360
        )
        harness.tableView.contentSize = newDelayedSize
        XCTAssertGreaterThan(distanceFromBottom(harness.tableView), 170)

        harness.coordinator.tableViewContentSizeDidChange(
            harness.tableView,
            oldSize: oldDelayedSize,
            newSize: newDelayedSize
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        harness.tableView.layoutIfNeeded()

        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)
    }

    @MainActor
    func testCoordinatorPreservesVisibleAnchorWhenEarlierRowsArePrepended() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        harness.tableView.scrollToRow(at: IndexPath(row: 30, section: 0), at: .top, animated: false)
        harness.tableView.layoutIfNeeded()

        let anchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let anchoredRowID = rows[anchoredIndexPath.row].id
        let anchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: anchoredIndexPath).minY

        let prependedRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 10, idPrefix: "older") + makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: prependedRows,
            earlierMessageCount: 0,
            scrollIntent: nil
        )
        pumpLayout(for: harness.tableView)

        let newAnchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let newAnchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: newAnchoredIndexPath).minY
        XCTAssertEqual(prependedRows[newAnchoredIndexPath.row].id, anchoredRowID)
        XCTAssertLessThan(abs(newAnchoredOffset - anchoredOffset), 2)
    }

    @MainActor
    func testCoordinatorAppliesMessageIntentAfterTargetRowAppears() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 30),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let scrollIntent = TranscriptScrollIntent(
            target: .message("message-45"),
            anchor: .top,
            animated: false,
            sequence: 1
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: scrollIntent
        )
        pumpLayout(for: harness.tableView)

        let expandedRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 60),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: expandedRows,
            earlierMessageCount: 0,
            scrollIntent: scrollIntent
        )
        pumpLayout(for: harness.tableView)

        XCTAssertEqual(harness.tableView.indexPathsForVisibleRows?.first, IndexPath(row: 45, section: 0))
    }

    @MainActor
    func testCoordinatorKeepsBottomPinnedWhenBoundsShrinkNearBottom() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)

        harness.tableView.frame = CGRect(x: 0, y: 0, width: 390, height: 360)
        harness.tableView.setNeedsLayout()
        pumpLayout(for: harness.tableView)

        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)
    }

    @MainActor
    func testCoordinatorIgnoresStaleBottomIntentAfterUserScrollsAway() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)

        harness.tableView.scrollToRow(at: IndexPath(row: 30, section: 0), at: .top, animated: false)
        harness.tableView.layoutIfNeeded()
        let anchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let anchoredRowID = rows[anchoredIndexPath.row].id

        let appendedRows = rows + [
            .message(
                ChatMessage(
                    id: "message-80",
                    role: .assistant,
                    createdAt: Date(timeIntervalSince1970: 80),
                    content: [.text("Newest assistant response")]
                )
            )
        ]
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: appendedRows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 2)
        )
        pumpLayout(for: harness.tableView)

        let newAnchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        XCTAssertEqual(appendedRows[newAnchoredIndexPath.row].id, anchoredRowID)
        XCTAssertGreaterThan(distanceFromBottom(harness.tableView), 170)
    }

    @MainActor
    func testCoordinatorDoesNotRevealEarlierMessagesDuringInitialProgrammaticBottomScrollWhenContentFits() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 1),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 10,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)

        XCTAssertEqual(harness.recorder.reachTopCount, 0)
    }

    @MainActor
    func testCoordinatorRevealsEarlierMessagesOnceWhenUserScrollsToTop() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 40),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 10,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        XCTAssertEqual(harness.recorder.reachTopCount, 0)

        harness.tableView.setContentOffset(
            CGPoint(x: 0, y: -harness.tableView.adjustedContentInset.top),
            animated: false
        )
        harness.coordinator.scrollViewDidScroll(harness.tableView)
        pumpLayout(for: harness.tableView)
        XCTAssertEqual(harness.recorder.reachTopCount, 1)

        harness.coordinator.scrollViewDidScroll(harness.tableView)
        pumpLayout(for: harness.tableView)
        XCTAssertEqual(harness.recorder.reachTopCount, 1)
    }
    #endif

    private func makeMessages(count: Int, idPrefix: String = "message") -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                id: "\(idPrefix)-\(index)",
                role: index.isMultiple(of: 2) ? .assistant : .user,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                content: [
                    .text("Synthetic message \(index)\n\nThis row intentionally has enough text to require normal chat cell layout.")
                ]
            )
        }
    }

    private func paragraphText(count: Int) -> String {
        (1...count)
            .map { "Paragraph \($0). This paragraph has enough text to wrap across multiple lines while the streaming response grows." }
            .joined(separator: "\n\n")
    }

    #if os(iOS)
    @MainActor
    private func makeCoordinatorHarness() throws -> CoordinatorHarness {
        let recorder = CallbackRecorder()
        let coordinator = UIKitTranscriptSurface.Coordinator(
            onReachTop: { recorder.reachTopCount += 1 },
            onNearBottomChanged: { recorder.nearBottomValues.append($0) }
        )
        let tableView = TranscriptTableViewFactory.make(
            dataSource: coordinator.dataSource,
            delegate: coordinator
        )
        tableView.onBoundsSizeChanged = { [weak coordinator] tableView, oldSize, newSize in
            coordinator?.tableViewBoundsDidChange(tableView, oldSize: oldSize, newSize: newSize)
        }
        tableView.onContentSizeChanged = { [weak coordinator] tableView, oldSize, newSize in
            coordinator?.tableViewContentSizeDidChange(tableView, oldSize: oldSize, newSize: newSize)
        }
        let window = try host(tableView)
        return CoordinatorHarness(
            window: window,
            tableView: tableView,
            coordinator: coordinator,
            recorder: recorder
        )
    }

    @MainActor
    private func host(_ tableView: UITableView) throws -> UIWindow {
        tableView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let controller = UIViewController()
        controller.view.frame = tableView.frame
        controller.view.addSubview(tableView)
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = tableView.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    @MainActor
    private func pumpLayout(for tableView: UITableView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        tableView.layoutIfNeeded()
    }

    @MainActor
    private func distanceFromBottom(_ tableView: UITableView) -> CGFloat {
        let visibleBottom = tableView.contentOffset.y
            + tableView.bounds.height
            - tableView.adjustedContentInset.bottom
        return tableView.contentSize.height - visibleBottom
    }

    private final class NoOpTableDelegate: NSObject, UITableViewDelegate {}

    private final class CallbackRecorder {
        var reachTopCount = 0
        var nearBottomValues: [Bool] = []
    }

    private struct CoordinatorHarness {
        let window: UIWindow
        let tableView: UITableView
        let coordinator: UIKitTranscriptSurface.Coordinator
        let recorder: CallbackRecorder
    }
    #endif
}
