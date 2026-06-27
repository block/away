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
}

struct SessionRuntime: Equatable, Sendable {
    var isReplaying = false
    var activeRunID: String?
    var streamingMessageID: String?
    var errorMessage: String?
}
