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
}
