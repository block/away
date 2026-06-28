import XCTest
@testable import GooseRemote

final class ChatTranscriptReducerTests: XCTestCase {
    func testAssistantChunksAppendToStableMessage() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(notification(kind: "agent_message_chunk", messageID: "m1", text: "Hello"))
        _ = reducer.apply(notification(kind: "agent_message_chunk", messageID: "m1", text: " world"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].id, "m1")
        XCTAssertEqual(reducer.messages[0].content, [.text("Hello world")])
    }

    func testLateAssistantReplayChunksDoNotDuplicateSnapshotText() {
        var reducer = ChatTranscriptReducer(
            messages: [
                ChatMessage(id: "m1", role: .assistant, content: [.text("Hello world")])
            ],
            runtime: SessionRuntime(snapshotMessageIDs: ["m1"])
        )

        _ = reducer.apply(notification(kind: "agent_message_chunk", messageID: "m1", text: "Hello"))
        _ = reducer.apply(notification(kind: "agent_message_chunk", messageID: "m1", text: " world"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].content, [.text("Hello world")])
    }

    func testSnapshotAssistantMessageReplacesWhitespaceVariantEcho() {
        var reducer = ChatTranscriptReducer(
            messages: [
                ChatMessage(id: "m1", role: .assistant, content: [.text("Hello")])
            ],
            runtime: SessionRuntime(snapshotMessageIDs: ["m1"])
        )

        _ = reducer.apply(notification(kind: "agent_message_chunk", messageID: "m1", text: " Hello from replay"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].content, [.text(" Hello from replay")])
    }

    func testReplayUserChunkSeparatesAssistantTurns() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(notification(kind: "agent_message_chunk", messageID: "a1", text: "first"))
        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: "next"))
        _ = reducer.apply(notification(kind: "agent_message_chunk", messageID: "a2", text: "second"))

        XCTAssertEqual(reducer.messages.map(\.id), ["a1", "u1", "a2"])
        XCTAssertEqual(reducer.messages[0].content, [.text("first")])
        XCTAssertEqual(reducer.messages[2].content, [.text("second")])
        XCTAssertFalse(reducer.messages[0].isStreaming)
    }

    func testLocalUserMessageSeparatesNextAssistantTurnWithoutMessageID() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(notification(kind: "agent_message_chunk", messageID: "a1", text: "first"))
        reducer.appendLocalUserMessage(id: "local-user", text: "next")
        _ = reducer.apply(
            ACPNotification(
                sessionID: "s1",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "agent_message_chunk",
                    "content": [
                        "type": "text",
                        "text": "second"
                    ]
                ])
            )
        )

        XCTAssertEqual(reducer.messages.map(\.role), [.assistant, .user, .assistant])
        XCTAssertEqual(reducer.messages[0].content, [.text("first")])
        XCTAssertEqual(reducer.messages[1].content, [.text("next")])
        XCTAssertEqual(reducer.messages[2].content, [.text("second")])
        XCTAssertFalse(reducer.messages[0].isStreaming)
    }

    func testUserReplayChunksAppendToUserMessage() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: "hi"))
        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: " there"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].role, .user)
        XCTAssertEqual(reducer.messages[0].content, [.text("hi there")])
    }

    func testOptimisticUserMessageIgnoresMatchingServerEchoChunks() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        reducer.appendLocalUserMessage(id: "u1", text: "hello")
        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: "hel"))
        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: "lo"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].content, [.text("hello")])
    }

    func testOptimisticUserMessageReplacesWithLongerServerEcho() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        reducer.appendLocalUserMessage(id: "u1", text: "hello")
        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: "hello!"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].content, [.text("hello!")])
    }

    func testOptimisticUserMessageReplacesWhitespaceVariantEcho() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        reducer.appendLocalUserMessage(id: "u1", text: "hello")
        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: " hello from replay"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].content, [.text(" hello from replay")])
    }

    func testOptimisticUserMessageIgnoresServerEchoWithDifferentIDAndSameText() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        reducer.appendLocalUserMessage(id: "local-id", text: "hello")
        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "server-id", text: " hello "))

        XCTAssertEqual(reducer.messages.map(\.id), ["local-id"])
        XCTAssertEqual(reducer.messages[0].content, [.text("hello")])
    }

    func testSnapshotUserMessageIgnoresMatchingReplayChunks() {
        var reducer = ChatTranscriptReducer(
            messages: [
                ChatMessage(id: "u1", role: .user, content: [.text("hello")])
            ],
            runtime: SessionRuntime(snapshotMessageIDs: ["u1"])
        )

        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: "hel"))
        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: "lo"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].content, [.text("hello")])
    }

    func testSnapshotUserMessageReplacesWhitespaceVariantEcho() {
        var reducer = ChatTranscriptReducer(
            messages: [
                ChatMessage(id: "u1", role: .user, content: [.text("hello")])
            ],
            runtime: SessionRuntime(snapshotMessageIDs: ["u1"])
        )

        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: " hello from replay"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].content, [.text(" hello from replay")])
    }

    func testSnapshotUserMessageIgnoresServerEchoWithDifferentIDAndSameText() {
        var reducer = ChatTranscriptReducer(
            messages: [
                ChatMessage(id: "local-id", role: .user, content: [.text("hello")])
            ],
            runtime: SessionRuntime(snapshotMessageIDs: ["local-id"])
        )

        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "server-id", text: " hello "))

        XCTAssertEqual(reducer.messages.map(\.id), ["local-id"])
        XCTAssertEqual(reducer.messages[0].content, [.text("hello")])
    }

    func testAssistantOnlyUserReplayChunkIsHidden() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        let result = reducer.apply(
            notification(
                kind: "user_message_chunk",
                messageID: "u1",
                text: "hidden context",
                audience: ["assistant"]
            )
        )

        XCTAssertTrue(reducer.messages.isEmpty)
        XCTAssertNil(result.subtitle)
    }

    func testEmptyAudienceUserReplayChunkIsHidden() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        let result = reducer.apply(
            notification(
                kind: "user_message_chunk",
                messageID: "u1",
                text: "hidden context",
                audience: []
            )
        )

        XCTAssertTrue(reducer.messages.isEmpty)
        XCTAssertNil(result.subtitle)
    }

    func testMissingAudienceUserReplayChunkIsVisible() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(notification(kind: "user_message_chunk", messageID: "u1", text: "visible context"))

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].content, [.text("visible context")])
    }

    func testUserAudienceReplayChunkIsVisible() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(
            notification(
                kind: "user_message_chunk",
                messageID: "u1",
                text: "visible context",
                audience: ["assistant", "user"]
            )
        )

        XCTAssertEqual(reducer.messages.count, 1)
        XCTAssertEqual(reducer.messages[0].content, [.text("visible context")])
    }

    func testToolUpdatePatchesExistingTool() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(
            ACPNotification(
                sessionID: "s1",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "tool_call",
                    "messageId": "m1",
                    "toolCallId": "tool1",
                    "title": "shell",
                    "status": "in_progress"
                ])
            )
        )
        _ = reducer.apply(
            ACPNotification(
                sessionID: "s1",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "tool1",
                    "status": "completed",
                    "result": "done"
                ])
            )
        )

        guard case .tool(let tool) = reducer.messages[0].content[0] else {
            return XCTFail("Expected tool content")
        }
        XCTAssertEqual(tool.status, "completed")
        XCTAssertEqual(tool.result, "done")
    }

    func testAssistantTextAfterToolCreatesNotificationPreview() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(
            ACPNotification(
                sessionID: "s1",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "tool_call",
                    "messageId": "m1",
                    "toolCallId": "tool1",
                    "title": "shell",
                    "status": "completed"
                ])
            )
        )
        let result = reducer.apply(notification(kind: "agent_message_chunk", messageID: "m1", text: "done"))

        XCTAssertEqual(result.assistantNotification, AssistantNotification(messageID: "m1", preview: "done"))
    }

    func testSessionInfoUpdateTracksActiveRunID() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(
            ACPNotification(
                sessionID: "s1",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "session_info_update",
                    "_meta": [
                        "goose": [
                            "activeRunId": "run-1"
                        ]
                    ]
                ])
            )
        )

        XCTAssertEqual(reducer.runtime.activeRunID, "run-1")
    }

    func testSessionInfoUpdateWithNullActiveRunIDEndsStreaming() {
        var reducer = ChatTranscriptReducer(messages: [], runtime: SessionRuntime())

        _ = reducer.apply(notification(kind: "agent_message_chunk", messageID: "a1", text: "streaming"))
        _ = reducer.apply(
            ACPNotification(
                sessionID: "s1",
                update: ACPUpdate(raw: [
                    "sessionUpdate": "session_info_update",
                    "_meta": [
                        "goose": [
                            "activeRunId": .null
                        ]
                    ]
                ])
            )
        )

        XCTAssertNil(reducer.runtime.activeRunID)
        XCTAssertNil(reducer.runtime.streamingMessageID)
        XCTAssertFalse(reducer.messages[0].isStreaming)
    }

    private func notification(
        kind: String,
        messageID: String,
        text: String,
        audience: [String]? = nil
    ) -> ACPNotification {
        var content: [String: JSONValue] = [
            "type": "text",
            "text": .string(text)
        ]
        if let audience {
            content["annotations"] = [
                "audience": .array(audience.map(JSONValue.string))
            ]
        }

        return ACPNotification(
            sessionID: "s1",
            update: ACPUpdate(raw: [
                "sessionUpdate": .string(kind),
                "messageId": .string(messageID),
                "content": .object(content)
            ])
        )
    }
}
