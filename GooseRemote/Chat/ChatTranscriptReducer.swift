import Foundation

struct ChatTranscriptReducer {
    var messages: [ChatMessage]
    var runtime: SessionRuntime

    mutating func appendLocalUserMessage(id: String, text: String, createdAt: Date = Date()) {
        finishStreamingMessage()
        messages.append(
            ChatMessage(
                id: id,
                role: .user,
                createdAt: createdAt,
                content: [.text(text)]
            )
        )
    }

    mutating func apply(_ notification: ACPNotification) -> TranscriptApplyResult {
        let update = notification.update
        var result = TranscriptApplyResult()

        if let activeRunID = update.activeRunID {
            runtime.activeRunID = activeRunID
        }

        switch update.kind {
        case "agent_message", "agent_message_chunk":
            if let content = update.content {
                let messageID = ensureAssistantMessage(id: update.messageID)
                if let text = textContent(from: content), !text.isEmpty {
                    let shouldNotify = hasNoTextContent(messageID: messageID)
                    appendText(text, to: messageID)
                    result.subtitle = text
                    if shouldNotify {
                        result.assistantNotification = AssistantNotification(messageID: messageID, preview: text)
                    }
                } else if let image = imageContent(from: content) {
                    appendContent(.image(data: image.data, mimeType: image.mimeType), to: messageID)
                }
            }

        case "user_message", "user_message_chunk":
            if let content = update.content,
               !isAssistantOnly(content),
               let text = textContent(from: content) {
                finishStreamingMessage()
                let messageID = update.messageID ?? UUID().uuidString
                appendUserText(text, messageID: messageID)
                result.subtitle = text
            }

        case "tool_call":
            let messageID = ensureAssistantMessage(id: update.messageID)
            let tool = ToolActivity(
                id: update.toolCallID ?? UUID().uuidString,
                name: update.title ?? "Tool",
                status: update.status ?? "in_progress"
            )
            appendContent(.tool(tool), to: messageID)
            result.subtitle = "Tool \(tool.status): \(tool.name)"

        case "tool_call_update":
            if let toolID = update.toolCallID {
                updateTool(toolID: toolID, update: update)
                result.subtitle = "Tool \(update.status ?? "updated")"
            }

        case "session_info_update":
            result.sessionTitle = update.raw["title"]?.stringValue
            if let activeRunID = update.activeRunID, activeRunID == nil {
                finishStreamingMessage()
            }

        case "usage_update", "config_option_update":
            break

        case "task_complete", "turn_complete", "session_idle", "agent_turn_complete":
            runtime.activeRunID = nil
            finishStreamingMessage()

        default:
            break
        }

        return result
    }

    private mutating func ensureAssistantMessage(id preferredID: String?) -> String {
        if let preferredID {
            if !messages.contains(where: { $0.id == preferredID }) {
                messages.append(
                    ChatMessage(
                        id: preferredID,
                        role: .assistant,
                        content: [],
                        isStreaming: true
                    )
                )
            }
            runtime.streamingMessageID = preferredID
            return preferredID
        }

        if let streamingMessageID = runtime.streamingMessageID,
           messages.contains(where: { $0.id == streamingMessageID }) {
            return streamingMessageID
        }

        let id = UUID().uuidString
        messages.append(
            ChatMessage(
                id: id,
                role: .assistant,
                content: [],
                isStreaming: true
            )
        )
        runtime.streamingMessageID = id
        return id
    }

    private mutating func appendText(_ text: String, to messageID: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        if case .text(let existing) = messages[index].content.last {
            messages[index].content[messages[index].content.count - 1] = .text(existing + text)
        } else {
            messages[index].content.append(.text(text))
        }
    }

    private mutating func appendUserText(_ text: String, messageID: String) {
        if let index = messages.firstIndex(where: { $0.id == messageID }),
           case .text(let existing) = messages[index].content.last {
            messages[index].content[messages[index].content.count - 1] = .text(existing + text)
        } else if messages.contains(where: { $0.id == messageID }) {
            appendContent(.text(text), to: messageID)
        } else {
            messages.append(ChatMessage(id: messageID, role: .user, content: [.text(text)]))
        }
    }

    private mutating func appendContent(_ content: ChatContent, to messageID: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].content.append(content)
    }

    private mutating func updateTool(toolID: String, update: ACPUpdate) {
        for messageIndex in messages.indices.reversed() {
            for contentIndex in messages[messageIndex].content.indices {
                guard case .tool(var tool) = messages[messageIndex].content[contentIndex],
                      tool.id == toolID
                else {
                    continue
                }
                if let title = update.title {
                    tool.name = title
                }
                if let status = update.status {
                    tool.status = status
                }
                tool.result = update.raw["result"]?.stringValue
                    ?? update.raw["content"]?.objectValue?["text"]?.stringValue
                    ?? tool.result
                messages[messageIndex].content[contentIndex] = .tool(tool)
                return
            }
        }

        let messageID = ensureAssistantMessage(id: update.messageID)
        appendContent(
            .tool(
                ToolActivity(
                    id: toolID,
                    name: update.title ?? "Tool",
                    status: update.status ?? "updated",
                    result: update.raw["result"]?.stringValue
                )
            ),
            to: messageID
        )
    }

    private mutating func markStreaming(_ isStreaming: Bool, messageID: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].isStreaming = isStreaming
    }

    private mutating func finishStreamingMessage() {
        if let streamingMessageID = runtime.streamingMessageID {
            markStreaming(false, messageID: streamingMessageID)
        }
        runtime.streamingMessageID = nil
    }

    private func textContent(from object: [String: JSONValue]) -> String? {
        guard object["type"]?.stringValue == "text" else { return nil }
        return object["text"]?.stringValue
    }

    private func isAssistantOnly(_ object: [String: JSONValue]) -> Bool {
        guard let audience = object["annotations"]?["audience"]?.arrayValue else {
            return false
        }
        let roles = audience.compactMap(\.stringValue)
        return !roles.contains("user")
    }

    private func hasNoTextContent(messageID: String) -> Bool {
        guard let message = messages.first(where: { $0.id == messageID }) else {
            return true
        }
        return !message.content.contains {
            if case .text = $0 {
                return true
            }
            return false
        }
    }

    private func imageContent(from object: [String: JSONValue]) -> (data: String, mimeType: String)? {
        guard object["type"]?.stringValue == "image",
              let data = object["data"]?.stringValue,
              let mimeType = object["mimeType"]?.stringValue
        else {
            return nil
        }
        return (data, mimeType)
    }
}

struct TranscriptApplyResult: Equatable, Sendable {
    var subtitle: String?
    var sessionTitle: String?
    var assistantNotification: AssistantNotification?

    mutating func merge(_ other: TranscriptApplyResult) {
        subtitle = other.subtitle ?? subtitle
        sessionTitle = other.sessionTitle ?? sessionTitle
        assistantNotification = other.assistantNotification ?? assistantNotification
    }
}

struct AssistantNotification: Equatable, Sendable {
    var messageID: String
    var preview: String
}
