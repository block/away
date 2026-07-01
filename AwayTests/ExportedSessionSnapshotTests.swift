import XCTest
@testable import Away

final class ExportedSessionSnapshotTests: XCTestCase {
    func testParseKeepsLatestUsefulMessagesAndStoresEarlierMessages() throws {
        let snapshot = try ExportedSessionSnapshot.parse(
            json: """
            {
              "conversation": [
                { "id": "hidden", "role": "assistant", "metadata": { "user_visible": false }, "content": "hidden" },
                { "id": "u1", "role": "user", "content": "first" },
                { "id": "a1", "role": "assistant", "content": [{ "type": "text", "text": "second" }] },
                { "id": "tool", "role": "assistant", "content": [{ "type": "toolResponse", "text": "tool output" }] },
                { "id": "a2", "role": "assistant", "content": [{ "type": "output_text", "text": "third" }] },
                { "id": "u2", "role": "user", "content": [{ "type": "text", "text": "fourth" }] }
              ]
            }
            """,
            tailLimit: 2
        )

        XCTAssertEqual(snapshot.earlierMessages.map(\.id), ["u1", "a1"])
        XCTAssertEqual(snapshot.visibleMessages.map(\.id), ["a2", "u2"])
        XCTAssertEqual(snapshot.visibleMessages.map(\.plainText), ["third", "fourth"])
    }

    func testParseDropsAssistantOnlyTextBlocks() throws {
        let snapshot = try ExportedSessionSnapshot.parse(
            json: """
            {
              "conversation": [
                {
                  "id": "a1",
                  "role": "assistant",
                  "content": [
                    {
                      "type": "text",
                      "text": "hidden",
                      "annotations": { "audience": ["assistant"] }
                    },
                    {
                      "type": "text",
                      "text": "visible",
                      "annotations": { "audience": ["assistant", "user"] }
                    }
                  ]
                }
              ]
            }
            """,
            tailLimit: 10
        )

        XCTAssertEqual(snapshot.visibleMessages.map(\.plainText), ["visible"])
    }

    func testParseSupportsMessagesFallbackWrappersGeneratedIDsAndDates() throws {
        let snapshot = try ExportedSessionSnapshot.parse(
            json: """
            {
              "messages": [
                {
                  "message": {
                    "role": "user",
                    "createdAt": "2026-06-27T01:00:00Z",
                    "content": [{ "type": "input_text", "text": "wrapped" }]
                  }
                },
                {
                  "messages": [
                    {
                      "id": "hidden",
                      "role": "assistant",
                      "metadata": { "userVisible": false },
                      "content": "hidden"
                    },
                    {
                      "id": "a1",
                      "role": "assistant",
                      "timestamp": "2026-06-27T01:01:00Z",
                      "content": [{ "type": "system_notification", "text": "nested" }]
                    }
                  ]
                }
              ]
            }
            """,
            tailLimit: 2
        )

        XCTAssertEqual(snapshot.visibleMessages.map(\.id), ["exported-message-1"])
        XCTAssertEqual(snapshot.visibleMessages.map(\.plainText), ["wrapped"])
        XCTAssertEqual(snapshot.visibleMessages[0].createdAt, ISO8601DateParsing.parse("2026-06-27T01:00:00Z"))
    }

    func testParseDropsSystemMessagesAndSystemNotificationBlocks() throws {
        let snapshot = try ExportedSessionSnapshot.parse(
            json: """
            {
              "conversation": [
                { "id": "s1", "role": "system", "content": "visible system text" },
                {
                  "id": "a1",
                  "role": "assistant",
                  "content": [{ "type": "system_notification", "text": "system notification" }]
                },
                {
                  "id": "a2",
                  "role": "assistant",
                  "content": [{ "type": "text", "text": "visible assistant text" }]
                }
              ]
            }
            """,
            tailLimit: 10
        )

        XCTAssertEqual(snapshot.visibleMessages.map(\.id), ["a2"])
        XCTAssertEqual(snapshot.visibleMessages.map(\.plainText), ["visible assistant text"])
    }

    func testParseAssignsUniqueFallbackDatesForExplicitIDsWithoutDates() throws {
        let snapshot = try ExportedSessionSnapshot.parse(
            json: """
            {
              "conversation": [
                { "id": "u1", "role": "user", "content": "first" },
                { "id": "a1", "role": "assistant", "content": "second" }
              ]
            }
            """,
            tailLimit: 10
        )

        XCTAssertEqual(
            snapshot.visibleMessages.map(\.createdAt),
            [
                Date(timeIntervalSince1970: 1),
                Date(timeIntervalSince1970: 2)
            ]
        )
    }

    func testParseThrowsWhenExportHasNoConversationOrMessages() {
        XCTAssertThrowsError(
            try ExportedSessionSnapshot.parse(json: #"{"sessionId":"s1"}"#, tailLimit: 10)
        )
    }

    func testAuthoritativeReplayReplacesSnapshotWithoutDuplicateTail() {
        let replay = ChatTranscriptReducer.authoritativeReplay(
            notifications: [
                notification(kind: "user_message_chunk", messageID: "u1", text: "first"),
                notification(kind: "agent_message_chunk", messageID: "a1", text: "second"),
                notification(kind: "agent_message_chunk", messageID: "a2", text: "third")
            ],
            preservingLocalPrompts: []
        )

        XCTAssertEqual(replay.messages.map(\.id), ["u1", "a1", "a2"])
        XCTAssertEqual(replay.messages.map(\.plainText), ["first", "second", "third"])
        XCTAssertTrue(replay.runtime.hasAuthoritativeReplay)
        XCTAssertFalse(replay.runtime.hasTailSnapshot)
    }

    func testAuthoritativeReplayPreservesQueuedPromptAfterReplay() {
        let replay = ChatTranscriptReducer.authoritativeReplay(
            notifications: [
                notification(kind: "agent_message_chunk", messageID: "a1", text: "loaded")
            ],
            preservingLocalPrompts: [
                QueuedPrompt(id: "local-1", text: "send after attach")
            ]
        )

        XCTAssertEqual(replay.messages.map(\.id), ["a1", "local-1"])
        XCTAssertEqual(replay.messages.map(\.plainText), ["loaded", "send after attach"])
        XCTAssertEqual(replay.runtime.queuedPromptCount, 1)
        XCTAssertEqual(replay.queuedPrompts, [QueuedPrompt(id: "local-1", text: "send after attach")])
    }

    func testAuthoritativeReplayDoesNotAppendQueuedPromptAlreadyInReplay() {
        let replay = ChatTranscriptReducer.authoritativeReplay(
            notifications: [
                notification(kind: "user_message_chunk", messageID: "local-1", text: "already replayed")
            ],
            preservingLocalPrompts: [
                QueuedPrompt(id: "local-1", text: "already replayed")
            ]
        )

        XCTAssertEqual(replay.messages.map(\.id), ["local-1"])
        XCTAssertEqual(replay.messages.map(\.plainText), ["already replayed"])
        XCTAssertEqual(replay.runtime.queuedPromptCount, 0)
        XCTAssertEqual(replay.queuedPrompts, [])
    }

    func testAuthoritativeReplayDoesNotPreserveQueuedPromptAlreadyReplayedWithDifferentIDAndSameText() {
        let replay = ChatTranscriptReducer.authoritativeReplay(
            notifications: [
                notification(kind: "user_message_chunk", messageID: "server-id", text: " already replayed ")
            ],
            preservingLocalPrompts: [
                QueuedPrompt(id: "local-1", text: "already replayed")
            ]
        )

        XCTAssertEqual(replay.messages.map(\.id), ["server-id"])
        XCTAssertEqual(replay.messages.map(\.plainText), ["already replayed"])
        XCTAssertEqual(replay.runtime.queuedPromptCount, 0)
        XCTAssertEqual(replay.queuedPrompts, [])
    }

    @MainActor
    func testPreparingPreservingOpenKeepsMessagesAndClearsStaleRuntimeState() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.messagesBySession["s1"] = [
            ChatMessage(id: "local", role: .user, content: [.text("queued")])
        ]
        model.earlierMessagesBySession["s1"] = [
            ChatMessage(id: "older", role: .assistant, content: [.text("older")])
        ]
        model.runtimeBySession["s1"] = SessionRuntime(
            isOpening: false,
            isReplaying: true,
            hasTailSnapshot: true,
            hasAuthoritativeReplay: false,
            queuedPromptCount: 1,
            activeRunID: "stale-run",
            streamingMessageID: "stale-stream",
            errorMessage: "stale error"
        )

        model.prepareOpenSessionState("s1", preservingExistingMessages: true)

        XCTAssertEqual(model.activeSessionID, "s1")
        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.id), ["local"])
        XCTAssertEqual(model.earlierMessagesBySession["s1"]?.map(\.id), ["older"])
        XCTAssertEqual(model.runtimeBySession["s1"]?.isOpening, true)
        XCTAssertEqual(model.runtimeBySession["s1"]?.isReplaying, false)
        XCTAssertNil(model.runtimeBySession["s1"]?.errorMessage)
        XCTAssertNil(model.runtimeBySession["s1"]?.activeRunID)
        XCTAssertNil(model.runtimeBySession["s1"]?.streamingMessageID)
    }

    @MainActor
    func testPreparingNonPreservingOpenClearsMessagesAndRetryAttempts() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.messagesBySession["s1"] = [
            ChatMessage(id: "local", role: .user, content: [.text("queued")])
        ]
        model.earlierMessagesBySession["s1"] = [
            ChatMessage(id: "older", role: .assistant, content: [.text("older")])
        ]
        model.setQueuedPromptsForTesting([QueuedPrompt(id: "q1", text: "queued")], for: "s1")
        _ = model.consumeNextQueuedPromptAttachRetryDecision(for: "s1")

        model.prepareOpenSessionState("s1", preservingExistingMessages: false)

        XCTAssertEqual(model.messagesBySession["s1"], [])
        XCTAssertEqual(model.earlierMessagesBySession["s1"], [])
        XCTAssertEqual(model.runtimeBySession["s1"], SessionRuntime(isOpening: true))
        XCTAssertNil(model.queuedPromptAttachRetryAttemptsForTesting(sessionID: "s1"))
    }

    @MainActor
    func testOpeningAuthoritativeSessionReusesLoadedTranscript() async {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.messagesBySession["s1"] = [
            ChatMessage(id: "loaded", role: .assistant, content: [.text("already loaded")])
        ]
        model.runtimeBySession["s1"] = SessionRuntime(
            isOpening: true,
            isReplaying: true,
            hasAuthoritativeReplay: true,
            errorMessage: "stale"
        )

        await model.openSession("s1")

        XCTAssertEqual(model.activeSessionID, "s1")
        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.id), ["loaded"])
        XCTAssertEqual(model.runtimeBySession["s1"]?.isOpening, false)
        XCTAssertEqual(model.runtimeBySession["s1"]?.isReplaying, false)
        XCTAssertEqual(model.runtimeBySession["s1"]?.hasAuthoritativeReplay, true)
        XCTAssertNil(model.runtimeBySession["s1"]?.errorMessage)
        XCTAssertEqual(model.connectionState, .disconnected)
    }

    @MainActor
    func testPreparingNavigationStartsStableLoadingState() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.messagesBySession["s1"] = [
            ChatMessage(id: "stale", role: .assistant, content: [.text("stale")])
        ]
        model.earlierMessagesBySession["s1"] = [
            ChatMessage(id: "older", role: .assistant, content: [.text("older")])
        ]
        model.setQueuedPromptsForTesting([QueuedPrompt(id: "q1", text: "queued")], for: "s1")
        _ = model.consumeNextQueuedPromptAttachRetryDecision(for: "s1")

        model.prepareSessionForNavigation("s1")

        XCTAssertEqual(model.activeSessionID, "s1")
        XCTAssertEqual(model.messagesBySession["s1"], [])
        XCTAssertEqual(model.earlierMessagesBySession["s1"], [])
        XCTAssertEqual(model.runtimeBySession["s1"], SessionRuntime(isOpening: true))
        XCTAssertNil(model.queuedPromptAttachRetryAttemptsForTesting(sessionID: "s1"))
    }

    @MainActor
    func testPreparingNavigationReusesAuthoritativeTranscript() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.messagesBySession["s1"] = [
            ChatMessage(id: "loaded", role: .assistant, content: [.text("already loaded")])
        ]
        model.runtimeBySession["s1"] = SessionRuntime(
            isOpening: true,
            isReplaying: true,
            hasAuthoritativeReplay: true,
            errorMessage: "stale"
        )

        model.prepareSessionForNavigation("s1")

        XCTAssertEqual(model.activeSessionID, "s1")
        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.id), ["loaded"])
        XCTAssertEqual(model.runtimeBySession["s1"]?.isOpening, false)
        XCTAssertEqual(model.runtimeBySession["s1"]?.isReplaying, false)
        XCTAssertEqual(model.runtimeBySession["s1"]?.hasAuthoritativeReplay, true)
        XCTAssertNil(model.runtimeBySession["s1"]?.errorMessage)
    }

    @MainActor
    func testQueuedPromptAttachRetryDecisionIsBoundedAndSetsGiveUpError() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.setQueuedPromptsForTesting([QueuedPrompt(id: "q1", text: "queued")], for: "s1")

        XCTAssertEqual(model.consumeNextQueuedPromptAttachRetryDecision(for: "s1"), .schedule(attempt: 1))
        XCTAssertEqual(model.consumeNextQueuedPromptAttachRetryDecision(for: "s1"), .schedule(attempt: 2))
        XCTAssertEqual(model.consumeNextQueuedPromptAttachRetryDecision(for: "s1"), .schedule(attempt: 3))
        XCTAssertEqual(model.consumeNextQueuedPromptAttachRetryDecision(for: "s1"), .exhausted)
        XCTAssertEqual(
            model.runtimeBySession["s1"]?.errorMessage,
            "Queued messages remain pending after 3 attach retries."
        )
    }

    @MainActor
    func testQueuedPromptAttachRetryDecisionClearsAttemptCountWhenQueueEmpties() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.setQueuedPromptsForTesting([QueuedPrompt(id: "q1", text: "queued")], for: "s1")
        _ = model.consumeNextQueuedPromptAttachRetryDecision(for: "s1")

        model.setQueuedPromptsForTesting([], for: "s1")

        XCTAssertEqual(model.consumeNextQueuedPromptAttachRetryDecision(for: "s1"), .none)
        XCTAssertNil(model.queuedPromptAttachRetryAttemptsForTesting(sessionID: "s1"))
    }

    @MainActor
    func testQueueingNewPromptResetsExhaustedAttachRetryBudget() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.setQueuedPromptsForTesting([QueuedPrompt(id: "q1", text: "queued")], for: "s1")
        _ = model.consumeNextQueuedPromptAttachRetryDecision(for: "s1")
        _ = model.consumeNextQueuedPromptAttachRetryDecision(for: "s1")
        _ = model.consumeNextQueuedPromptAttachRetryDecision(for: "s1")
        XCTAssertEqual(model.consumeNextQueuedPromptAttachRetryDecision(for: "s1"), .exhausted)

        model.queuePromptForTesting(id: "q2", text: "second queued", for: "s1")

        XCTAssertNil(model.queuedPromptAttachRetryAttemptsForTesting(sessionID: "s1"))
        XCTAssertEqual(model.consumeNextQueuedPromptAttachRetryDecision(for: "s1"), .schedule(attempt: 1))
    }

    @MainActor
    func testRevealEarlierMessagesPrependsAndClearsEarlierSnapshot() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.earlierMessagesBySession["s1"] = [
            ChatMessage(id: "older", role: .assistant, content: [.text("older")])
        ]
        model.messagesBySession["s1"] = [
            ChatMessage(id: "tail", role: .assistant, content: [.text("tail")])
        ]

        model.revealEarlierMessages(for: "s1")

        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.id), ["older", "tail"])
        XCTAssertEqual(model.earlierMessagesBySession["s1"], [])
    }

    @MainActor
    func testEmptyAuthoritativeReplayKeepsVisibleTailSnapshotNonAuthoritative() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        let snapshot = ExportedSessionSnapshot(
            visibleMessages: [
                ChatMessage(id: "tail", role: .assistant, content: [.text("recent tail")])
            ],
            earlierMessages: [
                ChatMessage(id: "older", role: .user, content: [.text("older")])
            ]
        )
        model.publishSnapshotForTesting(snapshot, for: "s1")

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: "s1")

        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.id), ["tail"])
        XCTAssertEqual(model.earlierMessagesBySession["s1"]?.map(\.id), ["older"])
        XCTAssertEqual(model.runtimeBySession["s1"]?.hasTailSnapshot, true)
        XCTAssertEqual(model.runtimeBySession["s1"]?.hasAuthoritativeReplay, false)
        XCTAssertEqual(model.runtimeBySession["s1"]?.isOpening, false)
        XCTAssertEqual(model.runtimeBySession["s1"]?.isReplaying, false)
        XCTAssertEqual(model.runtimeBySession["s1"]?.snapshotMessageIDs, Set(["tail", "older"]))
    }

    @MainActor
    func testAuthoritativeReplayReplacesTailSnapshotWhenReplayHasMessages() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        let snapshot = ExportedSessionSnapshot(
            visibleMessages: [
                ChatMessage(id: "tail", role: .assistant, content: [.text("recent tail")])
            ],
            earlierMessages: [
                ChatMessage(id: "older", role: .user, content: [.text("older")])
            ]
        )
        model.publishSnapshotForTesting(snapshot, for: "s1")
        model.appendPendingNotificationsForTesting([
            notification(kind: "agent_message_chunk", messageID: "loaded", text: "authoritative")
        ])

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: "s1")

        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.id), ["loaded"])
        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.plainText), ["authoritative"])
        XCTAssertEqual(model.earlierMessagesBySession["s1"], [])
        XCTAssertEqual(model.runtimeBySession["s1"]?.hasTailSnapshot, false)
        XCTAssertEqual(model.runtimeBySession["s1"]?.hasAuthoritativeReplay, true)
        XCTAssertEqual(model.runtimeBySession["s1"]?.snapshotMessageIDs, Set<String>())
    }

    @MainActor
    func testPublishingSnapshotCapsSessionPreview() throws {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [SessionSummary(id: "s1", title: "Session")]
        let longText = Array(repeating: "word", count: 80).joined(separator: "\n")
        let snapshot = ExportedSessionSnapshot(
            visibleMessages: [
                ChatMessage(id: "tail", role: .assistant, content: [.text(longText)])
            ],
            earlierMessages: []
        )

        model.publishSnapshotForTesting(snapshot, for: "s1")

        let subtitle = try XCTUnwrap(model.sessions.first?.subtitle)
        XCTAssertLessThanOrEqual(subtitle.count, 243)
        XCTAssertTrue(subtitle.hasSuffix("..."))
        XCTAssertFalse(subtitle.contains("\n"))
    }

    @MainActor
    func testPublishingSnapshotDoesNotRefreshSessionActivityTimestamp() throws {
        let olderActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let newerActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(
                id: "newer",
                title: "Newer",
                updatedAt: newerActivity,
                lastMessageAt: newerActivity,
                messageCount: 2
            ),
            SessionSummary(
                id: "viewed",
                title: "Viewed",
                updatedAt: olderActivity,
                lastMessageAt: olderActivity,
                messageCount: 4
            )
        ]
        let snapshot = ExportedSessionSnapshot(
            visibleMessages: [
                ChatMessage(id: "tail", role: .assistant, content: [.text("loaded preview")])
            ],
            earlierMessages: []
        )

        model.publishSnapshotForTesting(snapshot, for: "viewed")

        XCTAssertEqual(model.sessions.map(\.id), ["newer", "viewed"])
        let viewed = try XCTUnwrap(model.sessions.first { $0.id == "viewed" })
        XCTAssertEqual(viewed.subtitle, "loaded preview")
        XCTAssertEqual(viewed.updatedAt, olderActivity)
        XCTAssertEqual(viewed.lastMessageAt, olderActivity)
    }

    @MainActor
    func testExternalSessionInfoUpdateInsertsUnknownSession() throws {
        let existingActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let newSessionActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(
                id: "existing",
                title: "Existing",
                updatedAt: existingActivity,
                lastMessageAt: existingActivity,
                messageCount: 2
            )
        ]

        model.appendPendingNotificationsForTesting([
            ACPNotification(
                sessionID: "external-new",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "session_info_update",
                    "title": "New Goose2 chat",
                    "updatedAt": .string("2026-06-30T21:00:00Z"),
                    "_meta": [
                        "createdAt": .string("2026-06-30T20:59:00Z"),
                        "lastMessageAt": .string("2026-06-30T21:00:00Z"),
                        "lastMessageSnippet": "Draft from Goose2",
                        "messageCount": 1
                    ]
                ])
            )
        ])

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: nil)

        XCTAssertEqual(model.sessions.map(\.id), ["external-new", "existing"])
        let inserted = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(inserted.title, "New Goose2 chat")
        XCTAssertEqual(inserted.subtitle, "Draft from Goose2")
        XCTAssertEqual(inserted.lastMessageAt, newSessionActivity)
        XCTAssertEqual(inserted.messageCount, 1)
    }

    @MainActor
    func testExternalArchivedSessionInfoUpdateDoesNotInsertUnknownSession() throws {
        let existingActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(
                id: "existing",
                title: "Existing",
                updatedAt: existingActivity,
                lastMessageAt: existingActivity,
                messageCount: 2
            )
        ]

        model.appendPendingNotificationsForTesting([
            ACPNotification(
                sessionID: "archived-elsewhere",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "session_info_update",
                    "title": "Archived Goose2 chat",
                    "_meta": [
                        "archivedAt": .string("2026-06-30T21:00:00Z")
                    ]
                ])
            )
        ])

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: nil)

        XCTAssertEqual(model.sessions.map(\.id), ["existing"])
    }

    @MainActor
    func testExternalArchivedSessionInfoUpdateRemovesExistingSession() throws {
        let existingActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let archivedActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(id: "other", title: "Other", updatedAt: existingActivity, messageCount: 2),
            SessionSummary(id: "archived", title: "Archived", updatedAt: archivedActivity, messageCount: 2)
        ]
        model.activeSessionID = "archived"

        model.appendPendingNotificationsForTesting([
            ACPNotification(
                sessionID: "archived",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "session_info_update",
                    "_meta": [
                        "archivedAt": .string("2026-06-30T22:00:00Z")
                    ]
                ])
            )
        ])

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: nil)

        XCTAssertEqual(model.sessions.map(\.id), ["other"])
        XCTAssertNil(model.activeSessionID)
    }

    @MainActor
    func testAuthoritativeReplayDoesNotRefreshSessionActivityTimestamp() throws {
        let olderActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let newerActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let viewedUpdatedAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T22:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(
                id: "newer",
                title: "Newer",
                updatedAt: newerActivity,
                lastMessageAt: newerActivity,
                messageCount: 2
            ),
            SessionSummary(
                id: "viewed",
                title: "Viewed",
                updatedAt: olderActivity,
                lastMessageAt: olderActivity,
                messageCount: 4
            )
        ]
        model.appendPendingNotificationsForTesting([
            ACPNotification(
                sessionID: "viewed",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "session_info_update",
                    "updatedAt": .string("2026-06-30T22:00:00Z")
                ])
            ),
            notification(
                kind: "agent_message_chunk",
                messageID: "loaded",
                text: "authoritative preview",
                sessionID: "viewed"
            )
        ])

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: "viewed")

        XCTAssertEqual(model.sessions.map(\.id), ["newer", "viewed"])
        let viewed = try XCTUnwrap(model.sessions.first { $0.id == "viewed" })
        XCTAssertEqual(viewed.subtitle, "authoritative preview")
        XCTAssertEqual(viewed.updatedAt, olderActivity)
        XCTAssertEqual(viewed.lastMessageAt, olderActivity)
        XCTAssertNotEqual(viewed.updatedAt, viewedUpdatedAt)
    }

    @MainActor
    func testLiveMessageActivityMovesSessionByLastMessageTimestamp() throws {
        let olderActivity = Date().addingTimeInterval(-7_200)
        let newerActivity = Date().addingTimeInterval(-3_600)
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(
                id: "newer",
                title: "Newer",
                updatedAt: newerActivity,
                lastMessageAt: newerActivity,
                messageCount: 2
            ),
            SessionSummary(
                id: "active",
                title: "Active",
                updatedAt: olderActivity,
                lastMessageAt: olderActivity,
                messageCount: 4
            )
        ]
        model.appendPendingNotificationsForTesting([
            notification(
                kind: "agent_message_chunk",
                messageID: "live",
                text: "fresh message",
                sessionID: "active"
            )
        ])

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: nil)

        XCTAssertEqual(model.sessions.map(\.id), ["active", "newer"])
        let active = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(active.subtitle, "fresh message")
        XCTAssertGreaterThan(active.lastMessageAt ?? .distantPast, newerActivity)
    }

    @MainActor
    func testLiveMessageActivityUsesObservedTimeWhenServerLastMessageAtIsStale() throws {
        let staleServerActivity = Date().addingTimeInterval(-7_200)
        let newerActivity = Date().addingTimeInterval(-3_600)
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(
                id: "newer",
                title: "Newer",
                updatedAt: newerActivity,
                lastMessageAt: newerActivity,
                messageCount: 2
            ),
            SessionSummary(
                id: "streaming",
                title: "Streaming",
                updatedAt: staleServerActivity,
                lastMessageAt: staleServerActivity,
                messageCount: 4
            )
        ]
        model.appendPendingNotificationsForTesting([
            ACPNotification(
                sessionID: "streaming",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "session_info_update",
                    "_meta": [
                        "lastMessageAt": .string(ISO8601DateFormatter().string(from: staleServerActivity))
                    ]
                ])
            ),
            notification(
                kind: "agent_message_chunk",
                messageID: "live",
                text: "fresh message",
                sessionID: "streaming"
            )
        ])

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: nil)

        XCTAssertEqual(model.sessions.map(\.id), ["streaming", "newer"])
        XCTAssertGreaterThan(model.sessions.first?.lastMessageAt ?? .distantPast, newerActivity)
    }

    @MainActor
    func testMetadataOnlyUpdatedAtDoesNotRefreshSessionActivityTimestamp() throws {
        let olderActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let newerActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let metadataUpdatedAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T22:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(id: "newer", title: "Newer", updatedAt: newerActivity, messageCount: 2),
            SessionSummary(id: "viewed", title: "Viewed", updatedAt: olderActivity, messageCount: 4)
        ]
        model.appendPendingNotificationsForTesting([
            ACPNotification(
                sessionID: "viewed",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "session_info_update",
                    "updatedAt": .string("2026-06-30T22:00:00Z")
                ])
            )
        ])

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: nil)

        XCTAssertEqual(model.sessions.map(\.id), ["newer", "viewed"])
        XCTAssertEqual(model.sessions.first { $0.id == "viewed" }?.updatedAt, olderActivity)
        XCTAssertNotEqual(model.sessions.first { $0.id == "viewed" }?.updatedAt, metadataUpdatedAt)
    }

    @MainActor
    func testSessionListRefreshPreservesFallbackUpdatedAtWhenMessageCountIsUnchanged() throws {
        let olderActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let newerActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let viewedUpdatedAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T22:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(id: "newer", title: "Newer", updatedAt: newerActivity, messageCount: 2),
            SessionSummary(id: "viewed", title: "Viewed", updatedAt: olderActivity, messageCount: 4)
        ]

        model.replaceSessionsForTesting(with: [
            SessionSummary(id: "viewed", title: "Viewed", updatedAt: viewedUpdatedAt, messageCount: 4),
            SessionSummary(id: "newer", title: "Newer", updatedAt: newerActivity, messageCount: 2)
        ])

        XCTAssertEqual(model.sessions.map(\.id), ["newer", "viewed"])
        XCTAssertEqual(model.sessions.first { $0.id == "viewed" }?.updatedAt, olderActivity)
    }

    @MainActor
    func testSessionListRefreshOrdersByLastMessageAtBeforeUpdatedAt() throws {
        let olderLastMessageAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let newerLastMessageAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let newerGenericUpdate = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T23:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())

        model.replaceSessionsForTesting(with: [
            SessionSummary(
                id: "generic-newer",
                title: "Generic newer",
                updatedAt: newerGenericUpdate,
                lastMessageAt: olderLastMessageAt,
                messageCount: 4
            ),
            SessionSummary(
                id: "message-newer",
                title: "Message newer",
                updatedAt: olderLastMessageAt,
                lastMessageAt: newerLastMessageAt,
                messageCount: 4
            )
        ])

        XCTAssertEqual(model.sessions.map(\.id), ["message-newer", "generic-newer"])
    }

    @MainActor
    func testSessionListRefreshKeepsNewerLocalLastMessageAt() throws {
        let staleServerLastMessageAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let competingLastMessageAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let localLastMessageAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T22:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(
                id: "active",
                title: "Active",
                updatedAt: localLastMessageAt,
                lastMessageAt: localLastMessageAt,
                messageCount: 4
            ),
            SessionSummary(
                id: "competing",
                title: "Competing",
                updatedAt: competingLastMessageAt,
                lastMessageAt: competingLastMessageAt,
                messageCount: 4
            )
        ]

        model.replaceSessionsForTesting(with: [
            SessionSummary(
                id: "active",
                title: "Active",
                updatedAt: staleServerLastMessageAt,
                lastMessageAt: staleServerLastMessageAt,
                messageCount: 4
            ),
            SessionSummary(
                id: "competing",
                title: "Competing",
                updatedAt: competingLastMessageAt,
                lastMessageAt: competingLastMessageAt,
                messageCount: 4
            )
        ])

        XCTAssertEqual(model.sessions.map(\.id), ["active", "competing"])
        XCTAssertEqual(model.sessions.first?.lastMessageAt, localLastMessageAt)
    }

    @MainActor
    func testSessionListRefreshAcceptsServerLastMessageAtWhenMessageCountChanges() throws {
        let serverLastMessageAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let competingLastMessageAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let localLastMessageAt = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T22:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(
                id: "active",
                title: "Active",
                updatedAt: localLastMessageAt,
                lastMessageAt: localLastMessageAt,
                messageCount: 4
            ),
            SessionSummary(
                id: "competing",
                title: "Competing",
                updatedAt: competingLastMessageAt,
                lastMessageAt: competingLastMessageAt,
                messageCount: 4
            )
        ]

        model.replaceSessionsForTesting(with: [
            SessionSummary(
                id: "active",
                title: "Active",
                updatedAt: serverLastMessageAt,
                lastMessageAt: serverLastMessageAt,
                messageCount: 5
            ),
            SessionSummary(
                id: "competing",
                title: "Competing",
                updatedAt: competingLastMessageAt,
                lastMessageAt: competingLastMessageAt,
                messageCount: 4
            )
        ])

        XCTAssertEqual(model.sessions.map(\.id), ["competing", "active"])
        XCTAssertEqual(model.sessions.first { $0.id == "active" }?.lastMessageAt, serverLastMessageAt)
    }

    @MainActor
    func testSessionListRefreshUsesFallbackUpdatedAtWhenMessageCountChanges() throws {
        let olderActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let newerActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let messageActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T22:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.sessions = [
            SessionSummary(id: "newer", title: "Newer", updatedAt: newerActivity, messageCount: 2),
            SessionSummary(
                id: "changed",
                title: "Changed",
                updatedAt: olderActivity,
                lastMessageAt: olderActivity,
                messageCount: 4
            )
        ]

        model.replaceSessionsForTesting(with: [
            SessionSummary(id: "changed", title: "Changed", updatedAt: messageActivity, messageCount: 5),
            SessionSummary(id: "newer", title: "Newer", updatedAt: newerActivity, messageCount: 2)
        ])

        XCTAssertEqual(model.sessions.map(\.id), ["changed", "newer"])
        XCTAssertEqual(model.sessions.first?.updatedAt, messageActivity)
    }

    @MainActor
    func testSessionListRefreshFiltersArchivedSessions() throws {
        let activeActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T20:00:00Z"))
        let archivedActivity = try XCTUnwrap(ISO8601DateParsing.parse("2026-06-30T21:00:00Z"))
        let model = AppModel(connectionConfig: makeTestConnectionConfig())

        model.replaceSessionsForTesting(with: [
            SessionSummary(
                id: "archived",
                title: "Archived",
                updatedAt: archivedActivity,
                archivedAt: archivedActivity,
                messageCount: 2
            ),
            SessionSummary(id: "active", title: "Active", updatedAt: activeActivity, messageCount: 2)
        ])

        XCTAssertEqual(model.sessions.map(\.id), ["active"])
    }

    private func notification(kind: String, messageID: String, text: String) -> ACPNotification {
        ACPNotification(
            sessionID: "s1",
            update: ACPUpdate(raw: [
                "sessionUpdate": .string(kind),
                "messageId": .string(messageID),
                "content": [
                    "type": "text",
                    "text": .string(text)
                ]
            ])
        )
    }

    private func notification(
        kind: String,
        messageID: String,
        text: String,
        sessionID: String
    ) -> ACPNotification {
        ACPNotification(
            sessionID: sessionID,
            update: ACPUpdate(raw: [
                "sessionUpdate": .string(kind),
                "messageId": .string(messageID),
                "content": [
                    "type": "text",
                    "text": .string(text)
                ]
            ])
        )
    }

    private func makeTestConnectionConfig() -> RemoteConnectionConfig {
        let store = DemoConnectionSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return .demo(environment: [:], settingsStore: store)
    }
}
