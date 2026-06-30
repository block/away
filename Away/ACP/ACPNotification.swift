import Foundation

struct ACPNotification: Equatable, Sendable {
    let sessionID: String
    let update: ACPUpdate

    static func from(envelope: ACPEnvelope) -> ACPNotification? {
        guard envelope.method == "session/update" || envelope.method == "_goose/unstable/session/update",
              let params = envelope.params?.objectValue,
              let sessionID = params["sessionId"]?.stringValue,
              let updateObject = params["update"]?.objectValue
        else {
            return nil
        }

        return ACPNotification(sessionID: sessionID, update: ACPUpdate(raw: updateObject))
    }
}

struct ACPUpdate: Equatable, Sendable {
    let raw: [String: JSONValue]

    var kind: String {
        raw["sessionUpdate"]?.stringValue ?? "unknown"
    }

    var messageID: String? {
        raw["messageId"]?.stringValue
    }

    var content: [String: JSONValue]? {
        raw["content"]?.objectValue
    }

    var toolCallID: String? {
        raw["toolCallId"]?.stringValue
    }

    var title: String? {
        raw["title"]?.stringValue
    }

    var status: String? {
        raw["status"]?.stringValue
    }

    var rawInput: [String: JSONValue]? {
        raw["rawInput"]?.objectValue
            ?? raw["input"]?.objectValue
            ?? raw["arguments"]?.objectValue
    }

    var toolName: String? {
        toolIdentity?.toolName
    }

    var extensionName: String? {
        toolIdentity?.extensionName
    }

    var toolChainSummary: ToolActivityChainSummary? {
        guard let meta = raw["_meta"]?.objectValue,
              let goose = meta["goose"]?.objectValue,
              let chain = goose["toolChainSummary"]?.objectValue,
              let summary = chain["summary"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty,
              let count = chain["count"]?.intValue,
              count > 0
        else {
            return nil
        }
        return ToolActivityChainSummary(summary: summary, count: count)
    }

    var activeRunID: String?? {
        guard let meta = raw["_meta"]?.objectValue,
              let goose = meta["goose"]?.objectValue,
              goose.keys.contains("activeRunId")
        else {
            return nil
        }
        return goose["activeRunId"]?.stringValue
    }

    private var toolIdentity: (toolName: String?, extensionName: String?)? {
        guard let meta = raw["_meta"]?.objectValue,
              let goose = meta["goose"]?.objectValue
        else {
            return nil
        }

        let toolCall = goose["mcpApp"]?.objectValue ?? goose["toolCall"]?.objectValue
        guard let toolCall else {
            return nil
        }

        let toolName = toolCall["toolName"]?.stringValue
        let extensionName = toolCall["extensionName"]?.stringValue
        guard toolName != nil || extensionName != nil else {
            return nil
        }

        return (toolName, extensionName)
    }
}

struct ACPEnvelope: Codable, Equatable, Sendable {
    var jsonrpc: String?
    var id: Int?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: ACPRPCError?
}

struct ACPRPCError: Codable, Equatable, Sendable {
    var code: Int?
    var message: String
    var data: JSONValue?
}
