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
    func testSilentReplayDefersNotificationsUntilAuthoritativeFlush() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.setSilentReplayForTesting(true, sessionID: "s1")

        model.enqueueNotificationForTesting(
            notification(kind: "agent_message_chunk", messageID: "loaded", text: "authoritative")
        )
        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: nil)

        XCTAssertEqual(model.pendingNotificationCountForTesting(sessionID: "s1"), 1)
        XCTAssertNil(model.messagesBySession["s1"])

        model.setSilentReplayForTesting(false, sessionID: "s1")
        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: "s1")

        XCTAssertEqual(model.pendingNotificationCountForTesting(sessionID: "s1"), 0)
        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.id), ["loaded"])
        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.plainText), ["authoritative"])
        XCTAssertEqual(model.runtimeBySession["s1"]?.hasAuthoritativeReplay, true)
    }

    @MainActor
    func testAuthoritativeReplayPreservesUnreplayedOptimisticUserMessageWithoutQueueingIt() {
        let model = AppModel(connectionConfig: makeTestConnectionConfig())
        model.messagesBySession["s1"] = [
            ChatMessage(id: "local-user", role: .user, content: [.text("just sent")])
        ]
        model.runtimeBySession["s1"] = SessionRuntime(optimisticUserMessageIDs: ["local-user"])
        model.appendPendingNotificationsForTesting([
            notification(kind: "agent_message_chunk", messageID: "loaded", text: "already loaded")
        ])

        model.flushPendingNotificationsForTesting(authoritativeReplaySessionID: "s1")

        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.id), ["loaded", "local-user"])
        XCTAssertEqual(model.messagesBySession["s1"]?.map(\.plainText), ["already loaded", "just sent"])
        XCTAssertEqual(model.runtimeBySession["s1"]?.optimisticUserMessageIDs, ["local-user"])
        XCTAssertEqual(model.runtimeBySession["s1"]?.queuedPromptCount, 0)
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

    private func makeTestConnectionConfig() -> RemoteConnectionConfig {
        let store = DemoConnectionSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return .demo(environment: [:], settingsStore: store)
    }
}
