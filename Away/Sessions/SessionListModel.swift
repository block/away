import Foundation

struct SessionListModel: Equatable, Sendable {
    var sessions: [SessionSummary]
    var connectionLabel: String
    var errorMessage: String?
}
