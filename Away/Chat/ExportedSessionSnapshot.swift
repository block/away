import Foundation

struct ExportedSessionSnapshot: Equatable, Sendable {
    var visibleMessages: [ChatMessage]
    var earlierMessages: [ChatMessage]

    static func parse(json: String, tailLimit: Int) throws -> ExportedSessionSnapshot {
        precondition(tailLimit > 0, "tailLimit must be positive")

        let data = Data(json.utf8)
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        let conversation = root["conversation"] ?? root["messages"]
        guard let conversation else {
            throw ACPError.invalidResponse("_goose/unstable/session/export")
        }

        var nextGeneratedID = 0
        var nextFallbackTimestamp = 0
        let messages = flattenMessages(
            conversation,
            nextGeneratedID: &nextGeneratedID,
            nextFallbackTimestamp: &nextFallbackTimestamp
        )
        let splitIndex = max(0, messages.count - tailLimit)

        return ExportedSessionSnapshot(
            visibleMessages: Array(messages.suffix(tailLimit)),
            earlierMessages: Array(messages.prefix(splitIndex))
        )
    }

    private static func flattenMessages(
        _ value: JSONValue,
        nextGeneratedID: inout Int,
        nextFallbackTimestamp: inout Int
    ) -> [ChatMessage] {
        if let array = value.arrayValue {
            return array.flatMap {
                flattenMessages(
                    $0,
                    nextGeneratedID: &nextGeneratedID,
                    nextFallbackTimestamp: &nextFallbackTimestamp
                )
            }
        }

        guard let object = value.objectValue else {
            return []
        }

        if let wrappedMessage = object["message"] {
            return flattenMessages(
                wrappedMessage,
                nextGeneratedID: &nextGeneratedID,
                nextFallbackTimestamp: &nextFallbackTimestamp
            )
        }
        if let wrappedMessages = object["messages"] {
            return flattenMessages(
                wrappedMessages,
                nextGeneratedID: &nextGeneratedID,
                nextFallbackTimestamp: &nextFallbackTimestamp
            )
        }

        guard let message = parseMessage(
            object,
            nextGeneratedID: &nextGeneratedID,
            nextFallbackTimestamp: &nextFallbackTimestamp
        ) else {
            return []
        }
        return [message]
    }

    private static func parseMessage(
        _ object: [String: JSONValue],
        nextGeneratedID: inout Int,
        nextFallbackTimestamp: inout Int
    ) -> ChatMessage? {
        guard !isHiddenMessage(object),
              let role = parseRole(object["role"]),
              let contentValue = object["content"] ?? object["text"]
        else {
            return nil
        }

        let text = textBlocks(from: contentValue, role: role)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else {
            return nil
        }

        let id: String
        if let messageID = object["id"]?.stringValue ?? object["messageId"]?.stringValue {
            id = messageID
        } else {
            nextGeneratedID += 1
            id = "exported-message-\(nextGeneratedID)"
        }

        let createdAt: Date
        if let parsedDate = parseDate(object) {
            createdAt = parsedDate
        } else {
            nextFallbackTimestamp += 1
            createdAt = Date(timeIntervalSince1970: TimeInterval(nextFallbackTimestamp))
        }

        return ChatMessage(
            id: id,
            role: role,
            createdAt: createdAt,
            content: [.text(text)],
            isStreaming: false
        )
    }

    private static func textBlocks(from value: JSONValue, role: ChatMessage.Role) -> [String] {
        if let text = value.stringValue {
            return role == .user || role == .assistant ? [text] : []
        }
        if let array = value.arrayValue {
            return array.flatMap { textBlocks(from: $0, role: role) }
        }
        guard let object = value.objectValue else {
            return []
        }
        return textFromBlock(object)
    }

    private static func textFromBlock(_ object: [String: JSONValue]) -> [String] {
        guard !isAssistantOnlyBlock(object),
              let type = object["type"]?.stringValue,
              allowedTextBlockTypes.contains(type),
              let text = object["text"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }
        return [text]
    }

    private static func parseRole(_ value: JSONValue?) -> ChatMessage.Role? {
        switch value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user":
            return .user
        case "assistant":
            return .assistant
        default:
            return nil
        }
    }

    private static func parseDate(_ object: [String: JSONValue]) -> Date? {
        ISO8601DateParsing.parse(object["createdAt"]?.stringValue)
            ?? ISO8601DateParsing.parse(object["timestamp"]?.stringValue)
            ?? ISO8601DateParsing.parse(object["updatedAt"]?.stringValue)
    }

    private static func isHiddenMessage(_ object: [String: JSONValue]) -> Bool {
        guard let metadata = object["metadata"]?.objectValue else {
            return false
        }
        return metadata["user_visible"]?.boolValue == false
            || metadata["userVisible"]?.boolValue == false
    }

    private static func isAssistantOnlyBlock(_ object: [String: JSONValue]) -> Bool {
        guard let audience = object["annotations"]?["audience"]?.arrayValue else {
            return false
        }
        let roles = audience.compactMap(\.stringValue)
        return !roles.contains("user")
    }

    private static let allowedTextBlockTypes: Set<String> = [
        "text",
        "input_text",
        "output_text"
    ]
}
