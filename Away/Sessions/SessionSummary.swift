import Foundation

struct SessionSummary: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var cwd: String?
    var updatedAt: Date?
    var createdAt: Date?
    var lastMessageAt: Date?
    var archivedAt: Date?
    var providerID: String?
    var modelID: String?
    var personaID: String?
    var messageCount: Int
    var hasMessageCount: Bool
    var isWorking: Bool

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled session" : title
    }

    var activityAt: Date? {
        lastMessageAt ?? updatedAt ?? createdAt
    }

    var isArchived: Bool {
        archivedAt != nil
    }

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        cwd: String? = nil,
        updatedAt: Date? = nil,
        createdAt: Date? = nil,
        lastMessageAt: Date? = nil,
        archivedAt: Date? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        personaID: String? = nil,
        messageCount: Int = 0,
        hasMessageCount: Bool = true,
        isWorking: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.archivedAt = archivedAt
        self.providerID = providerID
        self.modelID = modelID
        self.personaID = personaID
        self.messageCount = messageCount
        self.hasMessageCount = hasMessageCount
        self.isWorking = isWorking
    }

    init?(json: JSONValue) {
        guard let object = json.objectValue,
              let id = object["sessionId"]?.stringValue ?? object["id"]?.stringValue
        else {
            return nil
        }
        let meta = object["_meta"]?.objectValue
        self.id = id
        self.title = object["title"]?.stringValue
            ?? object["name"]?.stringValue
            ?? object["summary"]?.stringValue
            ?? "Untitled session"
        self.subtitle = object["subtitle"]?.stringValue
            ?? meta?["lastMessageSnippet"]?.stringValue
        self.cwd = object["cwd"]?.stringValue
            ?? object["workingDirectory"]?.stringValue
            ?? object["projectPath"]?.stringValue
        self.updatedAt = ISO8601DateParsing.parse(object["updatedAt"]?.stringValue)
            ?? ISO8601DateParsing.parse(object["lastModified"]?.stringValue)
        self.createdAt = ISO8601DateParsing.parse(meta?["createdAt"]?.stringValue)
            ?? ISO8601DateParsing.parse(object["createdAt"]?.stringValue)
        self.lastMessageAt = ISO8601DateParsing.parse(meta?["lastMessageAt"]?.stringValue)
            ?? ISO8601DateParsing.parse(object["lastMessageAt"]?.stringValue)
        self.archivedAt = ISO8601DateParsing.parse(meta?["archivedAt"]?.stringValue)
        self.providerID = meta?["providerId"]?.stringValue
        self.modelID = meta?["modelId"]?.stringValue
        self.personaID = meta?["personaId"]?.stringValue
        if let messageCount = meta?["messageCount"]?.intValue {
            self.messageCount = messageCount
            self.hasMessageCount = true
        } else {
            self.messageCount = 0
            self.hasMessageCount = false
        }
        self.isWorking = false
    }

    init?(sessionID: String, sessionInfoUpdate update: ACPUpdate) {
        guard update.kind == "session_info_update" else { return nil }

        let meta = update.raw["_meta"]?.objectValue
        self.id = sessionID
        self.title = update.raw["title"]?.stringValue ?? "Untitled session"
        self.subtitle = meta?["lastMessageSnippet"]?.stringValue
        self.cwd = update.raw["cwd"]?.stringValue
            ?? update.raw["workingDirectory"]?.stringValue
            ?? update.raw["projectPath"]?.stringValue
        self.updatedAt = update.updatedAt
        self.createdAt = ISO8601DateParsing.parse(meta?["createdAt"]?.stringValue)
            ?? ISO8601DateParsing.parse(update.raw["createdAt"]?.stringValue)
        self.lastMessageAt = update.lastMessageAt
        self.archivedAt = ISO8601DateParsing.parse(meta?["archivedAt"]?.stringValue)
        self.providerID = meta?["providerId"]?.stringValue
        self.modelID = meta?["modelId"]?.stringValue
        self.personaID = meta?["personaId"]?.stringValue
        if let messageCount = meta?["messageCount"]?.intValue {
            self.messageCount = messageCount
            self.hasMessageCount = true
        } else {
            self.messageCount = 0
            self.hasMessageCount = false
        }
        if case .some(.some) = update.activeRunID {
            self.isWorking = true
        } else {
            self.isWorking = false
        }
    }

    static func isMoreRecent(_ lhs: SessionSummary, than rhs: SessionSummary) -> Bool {
        switch (lhs.activityAt, rhs.activityAt) {
        case (.some(let left), .some(let right)) where left != right:
            return left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.id > rhs.id
        }
    }

    func preservingStableActivity(from existing: SessionSummary) -> SessionSummary {
        var merged = self
        if let lastMessageAt {
            if let existingLastMessageAt = existing.lastMessageAt,
               hasMessageCount,
               existing.hasMessageCount,
               messageCount == existing.messageCount,
               existingLastMessageAt > lastMessageAt {
                merged.lastMessageAt = existingLastMessageAt
            }
            return merged
        }

        guard hasMessageCount,
              existing.hasMessageCount,
              messageCount == existing.messageCount
        else {
            return merged
        }

        if let existingLastMessageAt = existing.lastMessageAt {
            merged.lastMessageAt = existingLastMessageAt
        }
        if existing.lastMessageAt == nil,
           existing.updatedAt != nil {
            merged.updatedAt = existing.updatedAt
        }
        return merged
    }
}
