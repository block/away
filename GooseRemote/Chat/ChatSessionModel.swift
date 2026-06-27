import Foundation

struct ChatSessionModel: Equatable, Sendable {
    var session: SessionSummary
    var messages: [ChatMessage]
    var runtime: SessionRuntime
}
