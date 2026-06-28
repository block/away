import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
        case system
    }

    var id: String
    var role: Role
    var createdAt: Date
    var content: [ChatContent]
    var isStreaming: Bool

    init(
        id: String,
        role: Role,
        createdAt: Date = Date(),
        content: [ChatContent],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.content = content
        self.isStreaming = isStreaming
    }

    var plainText: String? {
        let text = content.compactMap { content -> String? in
            if case .text(let value) = content {
                return value
            }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : text
    }
}

struct SessionRuntime: Equatable, Sendable {
    var isOpening = false
    var isReplaying = false
    var hasTailSnapshot = false
    var hasAuthoritativeReplay = false
    var queuedPromptCount = 0
    var optimisticUserMessageIDs: Set<String> = []
    var snapshotMessageIDs: Set<String> = []
    var activeRunID: String?
    var streamingMessageID: String?
    var errorMessage: String?
}
