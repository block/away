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

    func testRowsCollapseAdjacentToolCallsIntoStableGroup() {
        let message = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [
                .text("I will check."),
                .tool(
                    makeTool(
                        id: "tool-1",
                        name: "shell",
                        arguments: ["command": "sq agent-tools slack --help"],
                        chainSummary: ToolActivityChainSummary(summary: "checked slack tooling help", count: 8)
                    )
                ),
                .tool(
                    makeTool(
                        id: "tool-2",
                        name: "shell",
                        arguments: ["command": "sq agent-tools slack search-messages --help"]
                    )
                ),
                .text("Done.")
            ]
        )

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].id, "message:assistant-1::segment:0")
        guard case .toolGroup(let group) = rows[1] else {
            return XCTFail("Expected grouped tool row")
        }
        XCTAssertEqual(rows[1].id, "tool-group:assistant-1::tool-group:1:tool-1")
        XCTAssertEqual(group.title, "checked slack tooling help (8 steps)")
        XCTAssertFalse(group.isExpanded)
        XCTAssertEqual(group.tools.map(\.id), ["tool-1", "tool-2"])
        XCTAssertEqual(rows[2].id, "message:assistant-1::segment:3")
    }

    func testRowsExpandToolGroupIntoOneLineSteps() {
        let message = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [
                .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                .tool(makeTool(id: "tool-2", name: "Edit", arguments: ["path": "/tmp/two.md"]))
            ]
        )
        let groupID = "assistant-1::tool-group:0:tool-1"

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: [],
            expandedToolGroupIDs: [groupID]
        )

        XCTAssertEqual(rows.map(\.id), [
            "tool-group:assistant-1::tool-group:0:tool-1",
            "tool-step:assistant-1::tool-group:0:tool-1::tool:0:tool-1",
            "tool-step:assistant-1::tool-group:0:tool-1::tool:1:tool-2"
        ])
        guard case .toolGroup(let group) = rows[0],
              case .toolStep(let firstStep) = rows[1],
              case .toolStep(let secondStep) = rows[2]
        else {
            return XCTFail("Expected expanded tool group rows")
        }

        XCTAssertTrue(group.isExpanded)
        XCTAssertEqual(group.title, "updated files (2 steps)")
        XCTAssertEqual(firstStep.tool.displayName, "viewing one.md")
        XCTAssertFalse(firstStep.isLastInGroup)
        XCTAssertEqual(secondStep.tool.displayName, "updating two.md")
        XCTAssertTrue(secondStep.isLastInGroup)
    }

    func testRowsKeepExpandedToolOutputOutOfTranscriptRows() {
        let largeOutput = String(repeating: "line with command output\n", count: 500)
        let message = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [
                .tool(
                    makeTool(
                        id: "tool-1",
                        name: "shell",
                        arguments: ["command": "cat /tmp/large.log"],
                        result: largeOutput
                    )
                ),
                .tool(
                    makeTool(
                        id: "tool-2",
                        name: "shell",
                        arguments: ["command": "tail /tmp/large.log"],
                        result: largeOutput
                    )
                )
            ]
        )
        let groupID = "assistant-1::tool-group:0:tool-1"

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: [],
            expandedToolGroupIDs: [groupID]
        )

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { row in
            if case .message = row {
                return false
            }
            return true
        })
        guard case .toolStep(let firstStep) = rows[1] else {
            return XCTFail("Expected compact tool step")
        }
        XCTAssertEqual(firstStep.tool.result, largeOutput)
    }

    func testRowsRenderSingleToolCallAsCompactStepWithoutGroup() {
        let tool = makeTool(
            id: "tool-1",
            name: "slack_search_messages",
            arguments: ["query": "launch blockers"]
        )
        let message = ChatMessage(id: "assistant-1", role: .assistant, content: [.tool(tool)])

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows.count, 1)
        guard case .toolStep(let step) = rows[0] else {
            return XCTFail("Expected compact tool step")
        }
        XCTAssertNil(step.groupID)
        XCTAssertEqual(step.tool.displayName, "searching slack messages for launch blockers")
    }

    func testToolGroupStatusAndActiveTitle() {
        let activeGroup = ToolActivityGroup(
            id: "group-1",
            tools: [
                makeTool(id: "tool-1", name: "Read", status: "completed", arguments: ["path": "/tmp/one.md"]),
                makeTool(id: "tool-2", name: "Read", status: "in_progress", arguments: ["path": "/tmp/two.md"])
            ],
            isExpanded: false
        )
        let failedGroup = ToolActivityGroup(
            id: "group-2",
            tools: [
                makeTool(id: "tool-1", name: "Read", status: "completed", arguments: ["path": "/tmp/one.md"]),
                makeTool(id: "tool-2", name: "Read", status: "failed", arguments: ["path": "/tmp/two.md"]),
                makeTool(id: "tool-3", name: "Read", status: "in_progress", arguments: ["path": "/tmp/three.md"])
            ],
            isExpanded: false
        )

        XCTAssertEqual(activeGroup.aggregateStatus, "in_progress")
        XCTAssertEqual(activeGroup.title, "working through 2 steps")
        XCTAssertEqual(failedGroup.aggregateStatus, "failed")
        XCTAssertEqual(failedGroup.title, "reviewed files (3 steps)")
    }

    func testToolGroupPresentationSeparatesStructuredTitleAndCountBadge() {
        let activeGroup = ToolActivityGroup(
            id: "active",
            tools: [
                makeTool(id: "tool-1", name: "Read", status: "completed", arguments: ["path": "/tmp/one.md"]),
                makeTool(id: "tool-2", name: "Read", status: "in_progress", arguments: ["path": "/tmp/two.md"])
            ],
            isExpanded: false
        )
        let summarizedGroup = ToolActivityGroup(
            id: "summary",
            tools: [
                makeTool(
                    id: "tool-1",
                    name: "shell",
                    arguments: ["command": "sq agent-tools slack search"],
                    chainSummary: ToolActivityChainSummary(summary: "checked slack tooling help", count: 8)
                ),
                makeTool(id: "tool-2", name: "shell", arguments: ["command": "date"])
            ],
            isExpanded: false
        )
        let fallbackGroup = ToolActivityGroup(
            id: "fallback",
            tools: [
                makeTool(id: "tool-1", name: "fetch", arguments: ["url": "https://example.com/one"]),
                makeTool(id: "tool-2", name: "fetch", arguments: ["url": "https://example.com/two"])
            ],
            isExpanded: false
        )

        XCTAssertEqual(activeGroup.compactTitle, "working through")
        XCTAssertEqual(activeGroup.countBadgeText, "2")
        XCTAssertEqual(activeGroup.title, "working through 2 steps")

        XCTAssertEqual(summarizedGroup.compactTitle, "checked slack tooling help")
        XCTAssertEqual(summarizedGroup.countBadgeText, "8")
        XCTAssertEqual(summarizedGroup.title, "checked slack tooling help (8 steps)")

        XCTAssertEqual(fallbackGroup.compactTitle, "checked resources")
        XCTAssertEqual(fallbackGroup.countBadgeText, "2")
        XCTAssertEqual(fallbackGroup.title, "checked resources (2 steps)")
    }

    func testToolGroupFallbackSummaryCategories() {
        let reviewedFiles = ToolActivityGroup(
            id: "reviewed",
            tools: [
                makeTool(id: "tool-1", name: "List"),
                makeTool(id: "tool-2", name: "Inspect")
            ],
            isExpanded: false
        )
        let ranCommands = ToolActivityGroup(
            id: "commands",
            tools: [
                makeTool(id: "tool-1", name: "shell", arguments: ["command": "ls -la"]),
                makeTool(id: "tool-2", name: "shell", arguments: ["command": "pwd"])
            ],
            isExpanded: false
        )
        let checkedResources = ToolActivityGroup(
            id: "resources",
            tools: [
                makeTool(id: "tool-1", name: "fetch", arguments: ["url": "https://example.com/one"]),
                makeTool(id: "tool-2", name: "fetch", arguments: ["url": "https://example.com/two"])
            ],
            isExpanded: false
        )
        let updatedFiles = ToolActivityGroup(
            id: "updates",
            tools: [
                makeTool(id: "tool-1", name: "Edit", arguments: ["path": "/tmp/one.md"]),
                makeTool(id: "tool-2", name: "Write", arguments: ["path": "/tmp/two.md"])
            ],
            isExpanded: false
        )

        XCTAssertEqual(reviewedFiles.title, "reviewed files (2 steps)")
        XCTAssertEqual(ranCommands.title, "ran commands (2 steps)")
        XCTAssertEqual(checkedResources.title, "checked resources (2 steps)")
        XCTAssertEqual(updatedFiles.title, "updated files (2 steps)")
    }

    func testRowsMatchMessageTargetForSegmentedToolTurns() {
        let message = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [
                .text("Before tools."),
                .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                .text("After tools.")
            ]
        )

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows.map(\.id), [
            "message:assistant-1::segment:0",
            "tool-step:assistant-1::tool:1:tool-1",
            "message:assistant-1::segment:2"
        ])
        XCTAssertTrue(rows[0].matchesMessageTarget("assistant-1"))
        XCTAssertTrue(rows[2].matchesMessageTarget("assistant-1"))
    }

    func testRowsMatchMessageTargetForToolOnlyTurns() {
        let groupedMessage = ChatMessage(
            id: "assistant-group",
            role: .assistant,
            content: [
                .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                .tool(makeTool(id: "tool-2", name: "Read", arguments: ["path": "/tmp/two.md"]))
            ]
        )
        let singleToolMessage = ChatMessage(
            id: "assistant-single",
            role: .assistant,
            content: [
                .tool(makeTool(id: "tool-3", name: "Read", arguments: ["path": "/tmp/three.md"]))
            ]
        )

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [groupedMessage, singleToolMessage],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows.map(\.id), [
            "tool-group:assistant-group::tool-group:0:tool-1",
            "tool-step:assistant-single::tool:0:tool-3"
        ])
        XCTAssertTrue(rows[0].matchesMessageTarget("assistant-group"))
        XCTAssertTrue(rows[1].matchesMessageTarget("assistant-single"))
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

    func testToolAnimationPolicyAnimatesToolRowsOnly() {
        let message = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [
                .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                .tool(makeTool(id: "tool-2", name: "Edit", arguments: ["path": "/tmp/two.md"]))
            ]
        )
        let groupID = "assistant-1::tool-group:0:tool-1"
        let collapsedRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let expandedRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: [],
            expandedToolGroupIDs: [groupID]
        )

        XCTAssertTrue(
            TranscriptRowAnimationPolicy.canAnimateIdentityChange(
                oldRows: collapsedRows,
                newRows: expandedRows
            )
        )

        let changedMessageRows = [
            TranscriptSurfaceRow.message(
                ChatMessage(id: "assistant", role: .assistant, content: [.text("Old")])
            )
        ]
        let newMessageRows = [
            TranscriptSurfaceRow.message(
                ChatMessage(id: "assistant", role: .assistant, content: [.text("New")])
            )
        ]
        XCTAssertFalse(
            TranscriptRowAnimationPolicy.canAnimateIdentityChange(
                oldRows: changedMessageRows,
                newRows: newMessageRows
            )
        )
        XCTAssertEqual(
            TranscriptRowAnimationPolicy.reloadAnimation(
                oldRow: changedMessageRows[0],
                newRow: newMessageRows[0]
            ),
            .none
        )
        XCTAssertEqual(
            TranscriptRowAnimationPolicy.reloadAnimation(
                oldRow: collapsedRows[0],
                newRow: expandedRows[0]
            ),
            .fade
        )
    }

    func testToolAnimationPolicyAnimatesExpandedToolAppendAndTitleUpdate() {
        let groupID = "assistant-1::tool-group:0:tool-1"
        let oldMessage = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [
                .tool(
                    makeTool(
                        id: "tool-1",
                        name: "Read",
                        arguments: ["path": "/tmp/one.md"],
                        chainSummary: ToolActivityChainSummary(summary: "reviewed files", count: 2)
                    )
                ),
                .tool(makeTool(id: "tool-2", name: "Read", arguments: ["path": "/tmp/two.md"]))
            ]
        )
        let newMessage = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            content: [
                .tool(
                    makeTool(
                        id: "tool-1",
                        name: "Read",
                        arguments: ["path": "/tmp/one.md"],
                        chainSummary: ToolActivityChainSummary(summary: "reviewed files", count: 3)
                    )
                ),
                .tool(makeTool(id: "tool-2", name: "Read", arguments: ["path": "/tmp/two.md"])),
                .tool(makeTool(id: "tool-3", name: "Read", arguments: ["path": "/tmp/three.md"]))
            ]
        )

        let oldRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [oldMessage],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: [],
            expandedToolGroupIDs: [groupID]
        )
        let newRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [newMessage],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: [],
            expandedToolGroupIDs: [groupID]
        )

        XCTAssertTrue(
            TranscriptRowAnimationPolicy.canAnimateIdentityChange(
                oldRows: oldRows,
                newRows: newRows
            )
        )
        XCTAssertEqual(
            TranscriptRowAnimationPolicy.reloadAnimation(
                oldRow: oldRows[0],
                newRow: newRows[0]
            ),
            .fade
        )
        XCTAssertEqual(newRows.last?.id, "tool-step:assistant-1::tool-group:0:tool-1::tool:2:tool-3")
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
    func testCoordinatorPreservesVisibleAnchorWhenAnimatedToolRowsInsertAboveViewport() throws {
        let harness = try makeCoordinatorHarness()
        let toolMessage = ChatMessage(
            id: "assistant-tools",
            role: .assistant,
            content: [
                .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                .tool(makeTool(id: "tool-2", name: "Read", arguments: ["path": "/tmp/two.md"]))
            ]
        )
        let collapsedRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [toolMessage] + makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let expandedRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [toolMessage] + makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: [],
            expandedToolGroupIDs: ["assistant-tools::tool-group:0:tool-1"]
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: collapsedRows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        harness.tableView.scrollToRow(at: IndexPath(row: 30, section: 0), at: .top, animated: false)
        harness.tableView.layoutIfNeeded()

        let anchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let anchoredRowID = collapsedRows[anchoredIndexPath.row].id
        let anchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: anchoredIndexPath).minY

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: expandedRows,
            earlierMessageCount: 0,
            scrollIntent: nil
        )
        pumpLayout(for: harness.tableView)

        let newAnchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let newAnchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: newAnchoredIndexPath).minY
        XCTAssertEqual(expandedRows[newAnchoredIndexPath.row].id, anchoredRowID)
        XCTAssertLessThan(abs(newAnchoredOffset - anchoredOffset), 2)
    }

    @MainActor
    func testCoordinatorPreservesAnchorWhenMessageBecomesSegmentedToolTurn() throws {
        let harness = try makeCoordinatorHarness()
        let textMessage = ChatMessage(
            id: "assistant-target",
            role: .assistant,
            content: [.text("I am about to inspect a file.")]
        )
        let segmentedMessage = ChatMessage(
            id: textMessage.id,
            role: .assistant,
            content: [
                .text("I am about to inspect a file."),
                .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                .text("The file looks relevant.")
            ]
        )
        let oldRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 30) + [textMessage] + makeMessages(count: 50, idPrefix: "later"),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let newRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 30) + [segmentedMessage] + makeMessages(count: 50, idPrefix: "later"),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: oldRows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        harness.tableView.scrollToRow(at: IndexPath(row: 30, section: 0), at: .top, animated: false)
        harness.tableView.layoutIfNeeded()

        let anchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        XCTAssertEqual(oldRows[anchoredIndexPath.row].id, "message:assistant-target")
        let anchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: anchoredIndexPath).minY

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: newRows,
            earlierMessageCount: 0,
            scrollIntent: nil
        )
        pumpLayout(for: harness.tableView)

        let newAnchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let newAnchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: newAnchoredIndexPath).minY
        XCTAssertEqual(newRows[newAnchoredIndexPath.row].id, "message:assistant-target::segment:0")
        XCTAssertLessThan(abs(newAnchoredOffset - anchoredOffset), 2)
        XCTAssertGreaterThan(distanceFromBottom(harness.tableView), 170)
    }

    @MainActor
    func testCoordinatorPreservesChunkAnchorWhenMessageBecomesSegmentedToolTurn() throws {
        let harness = try makeCoordinatorHarness()
        let longText = String(repeating: "This long assistant response should be chunked before tool content arrives. ", count: 360)
        let textMessage = ChatMessage(
            id: "assistant-target",
            role: .assistant,
            content: [.text(longText)]
        )
        let segmentedMessage = ChatMessage(
            id: textMessage.id,
            role: .assistant,
            content: [
                .text(longText),
                .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"]))
            ]
        )
        let oldRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 20) + [textMessage] + makeMessages(count: 40, idPrefix: "later"),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let newRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 20) + [segmentedMessage] + makeMessages(count: 40, idPrefix: "later"),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        let oldAnchorRow = try XCTUnwrap(oldRows.firstIndex { $0.id == "message:assistant-target::chunk:2" })
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: oldRows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        harness.tableView.scrollToRow(at: IndexPath(row: oldAnchorRow, section: 0), at: .top, animated: false)
        harness.tableView.layoutIfNeeded()

        let anchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        XCTAssertEqual(oldRows[anchoredIndexPath.row].id, "message:assistant-target::chunk:2")
        let anchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: anchoredIndexPath).minY

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: newRows,
            earlierMessageCount: 0,
            scrollIntent: nil
        )
        pumpLayout(for: harness.tableView)

        let newAnchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let newAnchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: newAnchoredIndexPath).minY
        XCTAssertEqual(newRows[newAnchoredIndexPath.row].id, "message:assistant-target::segment:0::chunk:2")
        XCTAssertLessThan(abs(newAnchoredOffset - anchoredOffset), 2)
        XCTAssertGreaterThan(distanceFromBottom(harness.tableView), 170)
    }

    func testReloadPlanReloadsChangedMessageSurvivorDuringAnimatedToolInsertion() {
        let createdAt = Date(timeIntervalSince1970: 1)
        let oldMessage = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            createdAt: createdAt,
            content: [
                .text("Before tools."),
                .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                .text("Partial response")
            ]
        )
        let newMessage = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            createdAt: createdAt,
            content: [
                .text("Before tools."),
                .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                .text("Complete response"),
                .tool(makeTool(id: "tool-2", name: "Read", arguments: ["path": "/tmp/two.md"]))
            ]
        )
        let oldRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [oldMessage],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let newRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [newMessage],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertTrue(
            TranscriptRowAnimationPolicy.canAnimateIdentityChange(
                oldRows: oldRows,
                newRows: newRows
            )
        )

        let sameIndexPlan = TranscriptRowReloadPlan.sameIndexSurvivors(
            oldRows: oldRows,
            newRows: newRows
        )
        XCTAssertEqual(sameIndexPlan.nonAnimatedIndexPaths, [IndexPath(row: 2, section: 0)])
        XCTAssertEqual(sameIndexPlan.animatedIndexPaths, [])
        XCTAssertEqual(sameIndexPlan.rowIDs, ["message:assistant-1::segment:2"])

        let shiftedVisiblePlan = TranscriptRowReloadPlan.visibleSurvivorsByID(
            oldRows: oldRows,
            newRows: newRows,
            visibleIndexPaths: [IndexPath(row: 2, section: 0)],
            excludingRowIDs: []
        )
        XCTAssertEqual(shiftedVisiblePlan.nonAnimatedIndexPaths, [IndexPath(row: 2, section: 0)])
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
    func testCoordinatorAppliesMessageIntentToSegmentedToolTurn() throws {
        let harness = try makeCoordinatorHarness()
        let messages = makeMessages(count: 20) + [
            ChatMessage(
                id: "assistant-tools",
                role: .assistant,
                content: [
                    .text("Before tools."),
                    .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                    .text("After tools.")
                ]
            )
        ] + makeMessages(count: 20, idPrefix: "later")
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: messages,
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let scrollIntent = TranscriptScrollIntent(
            target: .message("assistant-tools"),
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

        let firstVisibleIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        XCTAssertEqual(rows[firstVisibleIndexPath.row].id, "message:assistant-tools::segment:0")
    }

    @MainActor
    func testCoordinatorAppliesMessageIntentToToolOnlyTurn() throws {
        let harness = try makeCoordinatorHarness()
        let messages = makeMessages(count: 20) + [
            ChatMessage(
                id: "assistant-tools",
                role: .assistant,
                content: [
                    .tool(makeTool(id: "tool-1", name: "Read", arguments: ["path": "/tmp/one.md"])),
                    .tool(makeTool(id: "tool-2", name: "Read", arguments: ["path": "/tmp/two.md"]))
                ]
            )
        ] + makeMessages(count: 20, idPrefix: "later")
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: messages,
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let scrollIntent = TranscriptScrollIntent(
            target: .message("assistant-tools"),
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

        let firstVisibleIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        XCTAssertEqual(rows[firstVisibleIndexPath.row].id, "tool-group:assistant-tools::tool-group:0:tool-1")
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

    private func makeTool(
        id: String,
        name: String,
        status: String = "completed",
        arguments: [String: JSONValue] = [:],
        chainSummary: ToolActivityChainSummary? = nil,
        result: String? = nil
    ) -> ToolActivity {
        ToolActivity(
            id: id,
            name: name,
            status: status,
            arguments: arguments,
            chainSummary: chainSummary,
            result: result
        )
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
