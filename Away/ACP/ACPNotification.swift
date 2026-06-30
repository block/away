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
            ?? gooseMeta?["messageId"]?.stringValue
    }

    var createdAt: Date? {
        guard let created = gooseMeta?["created"]?.intValue else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(created))
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
        guard let gooseMeta,
              gooseMeta.keys.contains("activeRunId")
        else {
            return nil
        }
        return gooseMeta["activeRunId"]?.stringValue
    }

    private var gooseMeta: [String: JSONValue]? {
        raw["_meta"]?.objectValue?["goose"]?.objectValue
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
