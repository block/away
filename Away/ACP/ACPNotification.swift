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

    var activeRunID: String?? {
        guard let meta = raw["_meta"]?.objectValue,
              let goose = meta["goose"]?.objectValue,
              goose.keys.contains("activeRunId")
        else {
            return nil
        }
        return goose["activeRunId"]?.stringValue
    }

    var updatedAt: Date? {
        ISO8601DateParsing.parse(raw["updatedAt"]?.stringValue)
    }

    var lastMessageAt: Date? {
        let meta = raw["_meta"]?.objectValue
        return ISO8601DateParsing.parse(meta?["lastMessageAt"]?.stringValue)
            ?? ISO8601DateParsing.parse(raw["lastMessageAt"]?.stringValue)
    }

    var archivedAt: Date? {
        let meta = raw["_meta"]?.objectValue
        return ISO8601DateParsing.parse(meta?["archivedAt"]?.stringValue)
            ?? ISO8601DateParsing.parse(raw["archivedAt"]?.stringValue)
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
