import Foundation

enum ChatContent: Equatable, Sendable, Identifiable {
    case text(String)
    case image(data: String, mimeType: String)
    case tool(ToolActivity)
    case system(String)

    var id: String {
        switch self {
        case .text(let text):
            "text:\(text.hashValue)"
        case .image(let data, let mimeType):
            "image:\(mimeType):\(data.hashValue)"
        case .tool(let tool):
            "tool:\(tool.id)"
        case .system(let text):
            "system:\(text.hashValue)"
        }
    }
}

struct ToolActivity: Equatable, Sendable {
    var id: String
    var name: String
    var status: String
    var result: String?
}
