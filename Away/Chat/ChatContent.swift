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
    var arguments: [String: JSONValue]
    var toolName: String?
    var extensionName: String?
    var chainSummary: ToolActivityChainSummary?
    var result: String?

    init(
        id: String,
        name: String,
        status: String,
        arguments: [String: JSONValue] = [:],
        toolName: String? = nil,
        extensionName: String? = nil,
        chainSummary: ToolActivityChainSummary? = nil,
        result: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.arguments = arguments
        self.toolName = toolName
        self.extensionName = extensionName
        self.chainSummary = chainSummary
        self.result = result
    }

    var displayName: String {
        ToolActivityNamer.displayName(for: self)
    }

    var isActive: Bool {
        status == "in_progress" || status == "pending"
    }
}

struct ToolActivityChainSummary: Equatable, Sendable {
    var summary: String
    var count: Int
}

struct ToolActivityGroup: Identifiable, Equatable, Sendable {
    enum SummaryKind: String, Equatable, Sendable {
        case reviewingFiles
        case runningCommands
        case checkingResources
        case updatingFiles
    }

    private static let fileArgumentKeys = ["path", "file", "filePath", "filepath", "targetPath", "directory", "dir", "cwd", "folder"]

    var id: String
    var tools: [ToolActivity]
    var isExpanded: Bool

    var compactTitle: String {
        if aggregateStatus == "in_progress" || aggregateStatus == "pending" {
            return "working through"
        }

        if let summary = firstChainSummary?.summary.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }

        return fallbackSummaryTitle
    }

    var countBadgeText: String {
        "\(stepCount)"
    }

    var title: String {
        let stepLabel = stepCount == 1 ? "step" : "steps"

        if aggregateStatus == "in_progress" || aggregateStatus == "pending" {
            return "\(compactTitle) \(stepCount) \(stepLabel)"
        }

        return "\(compactTitle) (\(stepCount) \(stepLabel))"
    }

    var aggregateStatus: String {
        if tools.contains(where: { $0.status == "failed" }) {
            return "failed"
        }
        if tools.contains(where: { $0.status == "stopped" }) {
            return "stopped"
        }
        if tools.contains(where: { $0.status == "in_progress" }) {
            return "in_progress"
        }
        if tools.contains(where: { $0.status == "pending" }) {
            return "pending"
        }
        return "completed"
    }

    private var firstChainSummary: ToolActivityChainSummary? {
        tools.compactMap(\.chainSummary).first
    }

    private var stepCount: Int {
        max(firstChainSummary?.count ?? tools.count, tools.count)
    }

    private var fallbackSummaryTitle: String {
        switch dominantSummaryKind {
        case .reviewingFiles:
            return "reviewed files"
        case .runningCommands:
            return "ran commands"
        case .checkingResources:
            return "checked resources"
        case .updatingFiles:
            return "updated files"
        }
    }

    private var dominantSummaryKind: SummaryKind {
        let counts = tools.reduce(into: [SummaryKind: Int]()) { partialResult, tool in
            partialResult[Self.summaryKind(for: tool), default: 0] += 1
        }

        let reviewingFiles = counts[.reviewingFiles, default: 0]
        let runningCommands = counts[.runningCommands, default: 0]
        let checkingResources = counts[.checkingResources, default: 0]
        let updatingFiles = counts[.updatingFiles, default: 0]

        if updatingFiles > 0,
           updatingFiles >= reviewingFiles,
           updatingFiles >= runningCommands,
           updatingFiles >= checkingResources {
            return .updatingFiles
        }
        if checkingResources > reviewingFiles,
           checkingResources >= runningCommands {
            return .checkingResources
        }
        if runningCommands > reviewingFiles {
            return .runningCommands
        }
        return .reviewingFiles
    }

    private static func summaryKind(for tool: ToolActivity) -> SummaryKind {
        let label = tool.displayName.lowercased()
        if label.hasPrefix("checking")
            || label.hasPrefix("fetching")
            || label.hasPrefix("downloading")
            || label.contains(" url")
            || label.contains(" http") {
            return .checkingResources
        }
        if label.hasPrefix("updating")
            || label.hasPrefix("writing")
            || label.hasPrefix("editing")
            || label.hasPrefix("creating")
            || label.hasPrefix("deleting")
            || label.hasPrefix("moving")
            || label.hasPrefix("renaming") {
            return .updatingFiles
        }
        if label.hasPrefix("viewing"), hasFileArgument(tool) {
            return .reviewingFiles
        }
        if label.hasPrefix("running")
            || (label.hasPrefix("viewing") && label.contains(" help"))
            || label.contains(" command")
            || label.contains(" shell")
            || label.contains(" bash") {
            return .runningCommands
        }
        return .reviewingFiles
    }

    private static func hasFileArgument(_ tool: ToolActivity) -> Bool {
        fileArgumentKeys.contains { key in
            guard let value = tool.arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !value.isEmpty
        }
    }
}

struct ToolActivityStep: Identifiable, Equatable, Sendable {
    var id: String
    var groupID: String?
    var tool: ToolActivity
    var isLastInGroup: Bool
}

enum ToolActivityNamer {
    private static let commandKeys = ["command", "cmd", "script"]
    private static let searchKeys = ["query", "pattern", "search", "needle", "text"]
    private static let pathKeys = ["path", "file", "filePath", "filepath", "targetPath", "directory", "dir", "cwd", "folder"]
    private static let urlKeys = ["url", "uri", "href"]
    private static let genericNames: Set<String> = ["tool", "shell", "bash", "command", "terminal", "execute"]

    static func displayName(for tool: ToolActivity) -> String {
        let readableName = readableToolName(tool)
        if let command = stringArgument(tool.arguments, keys: commandKeys) {
            return commandDisplayName(command, fallbackName: readableName)
        }

        if let query = stringArgument(tool.arguments, keys: searchKeys),
           readableName.contains("search") {
            return searchDisplayName(readableName: readableName, query: query)
        }

        if let url = stringArgument(tool.arguments, keys: urlKeys) {
            return "checking \(displayResource(url))"
        }

        if let path = stringArgument(tool.arguments, keys: pathKeys),
           !isGeneric(readableName) {
            return pathDisplayName(readableName: readableName, path: path)
        }

        if !readableName.isEmpty, !isGeneric(readableName) {
            return readableName
        }

        return "using tool"
    }

    private static func readableToolName(_ tool: ToolActivity) -> String {
        let title = humanized(tool.name)
        if !title.isEmpty, !isGeneric(title) {
            return title
        }

        let toolName = tool.toolName.map(humanized)
        let extensionName = tool.extensionName.map(humanized)
        if let extensionName,
           let toolName,
           toolName.contains("search") {
            return "\(extensionName) \(toolName)"
        }

        let candidates = [
            toolName,
            extensionName,
            title.isEmpty ? nil : title
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            if !candidate.isEmpty, !isGeneric(candidate) {
                return candidate
            }
        }
        return ""
    }

    private static func stringArgument(_ arguments: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func commandDisplayName(_ command: String, fallbackName: String) -> String {
        let primaryCommand = command
            .components(separatedBy: "|")
            .first?
            .components(separatedBy: "&&")
            .first?
            .components(separatedBy: "||")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? command
        var tokens = primaryCommand
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        let hasHelpFlag = tokens.contains("--help") || tokens.contains("-h") || tokens.contains("help")
        tokens.removeAll { token in
            token == "--help" || token == "-h" || token == "help" || token.hasPrefix("-")
        }

        if tokens.count >= 2, tokens[0] == "sq", tokens[1] == "agent-tools" {
            tokens.removeFirst(2)
        }

        let commandSubject = tokens.prefix(4).map(humanized).joined(separator: " ")
        if hasHelpFlag, !commandSubject.isEmpty {
            return "viewing \(commandSubject) help"
        }
        if !commandSubject.isEmpty {
            return "running \(commandSubject)"
        }
        if !fallbackName.isEmpty, !isGeneric(fallbackName) {
            return fallbackName
        }
        return "running command"
    }

    private static func searchDisplayName(readableName: String, query: String) -> String {
        let subject = compactedWhitespace(readableName
            .replacingOccurrences(of: "searching", with: "")
            .replacingOccurrences(of: "search", with: "")
        )
        let shortQuery = shortened(query)
        if subject.isEmpty {
            return "searching \(shortQuery)"
        }
        return "searching \(subject) for \(shortQuery)"
    }

    private static func pathDisplayName(readableName: String, path: String) -> String {
        let file = basename(path)
        if readableName.contains(file.lowercased()) {
            return readableName
        }
        if readableName.hasPrefix("read") || readableName.hasPrefix("view") {
            return "viewing \(file)"
        }
        if readableName.hasPrefix("write") || readableName.hasPrefix("edit") || readableName.hasPrefix("update") {
            return "updating \(file)"
        }
        return "\(readableName) \(file)"
    }

    private static func displayResource(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else {
            return shortened(value)
        }
        return host
    }

    private static func humanized(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("mcp__") {
            text.removeFirst("mcp__".count)
        }
        text = text
            .replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactedWhitespace(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text
    }

    private static func basename(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? path
    }

    private static func shortened(_ value: String, limit: Int = 48) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "..."
    }

    private static func isGeneric(_ name: String) -> Bool {
        genericNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
