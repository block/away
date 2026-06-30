import Foundation
import SwiftUI

enum TranscriptScrollAnchor: Equatable, Sendable {
    case top
    case center
    case bottom
}

struct TranscriptScrollIntent: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case message(String)
        case bottom
    }

    var target: Target
    var anchor: TranscriptScrollAnchor
    var animated: Bool
    var sequence: Int
}

enum TranscriptSurfaceRow: Identifiable, Equatable {
    case sessionShell(SessionSummary)
    case message(ChatMessage)
    case assistantProgress(anchorMessageID: String)

    var id: String {
        switch self {
        case .sessionShell(let session):
            "session-shell:\(session.id)"
        case .message(let message):
            "message:\(message.id)"
        case .assistantProgress(let anchorMessageID):
            "assistant-progress:\(anchorMessageID)"
        }
    }
}

enum TranscriptSurfaceRows {
    static func make(
        session _: SessionSummary?,
        messages: [ChatMessage],
        isLoading: Bool,
        hasAuthoritativeReplay: Bool,
        snapshotMessageIDs: Set<String>,
        optimisticUserMessageIDs: Set<String>,
        showsAssistantProgress: Bool = false
    ) -> [TranscriptSurfaceRow] {
        let presentedMessages = TranscriptOpeningPresentationPolicy.presentedMessages(
            messages,
            isLoading: isLoading,
            hasAuthoritativeReplay: hasAuthoritativeReplay,
            snapshotMessageIDs: snapshotMessageIDs,
            optimisticUserMessageIDs: optimisticUserMessageIDs
        )

        var rows = presentedMessages.flatMap(rows)
        if showsAssistantProgress,
           let lastMessage = presentedMessages.last,
           lastMessage.role == .user,
           optimisticUserMessageIDs.contains(lastMessage.id) {
            rows.append(.assistantProgress(anchorMessageID: lastMessage.id))
        }
        return rows
    }

    private static func rows(for message: ChatMessage) -> [TranscriptSurfaceRow] {
        guard message.role == .assistant,
              message.content.count == 1,
              case .text(let text) = message.content[0]
        else {
            return [.message(message)]
        }

        let chunks = TranscriptTextChunker.chunks(text)
        guard chunks.count > 1 else { return [.message(message)] }

        return chunks.enumerated().map { index, chunk in
            var chunkedMessage = message
            chunkedMessage.id = index == 0 ? message.id : "\(message.id)::chunk:\(index)"
            chunkedMessage.content = [.text(chunk)]
            chunkedMessage.isStreaming = message.isStreaming && index == chunks.count - 1
            return .message(chunkedMessage)
        }
    }
}

enum TranscriptTextChunker {
    static let defaultCharacterLimit = 2_400

    static func chunks(_ text: String, limit: Int = defaultCharacterLimit) -> [String] {
        guard text.count > limit else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let limitedEnd = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            if limitedEnd == text.endIndex {
                chunks.append(String(text[start..<limitedEnd]))
                break
            }

            let slice = text[start..<limitedEnd]
            let minimumBreak = text.index(start, offsetBy: limit * 2 / 3, limitedBy: limitedEnd) ?? start
            let preferredBreak = slice[minimumBreak..<limitedEnd].lastIndex(where: { character in
                character.isNewline || character.isWhitespace
            }) ?? limitedEnd

            let chunkEnd = preferredBreak > start ? preferredBreak : limitedEnd
            chunks.append(String(text[start..<chunkEnd]))
            start = chunkEnd
            while start < text.endIndex, text[start].isWhitespace {
                chunks[chunks.count - 1].append(text[start])
                start = text.index(after: start)
            }
        }

        return chunks
    }
}

enum TranscriptOpeningPresentationPolicy {
    static func presentedMessages(
        _ messages: [ChatMessage],
        isLoading: Bool,
        hasAuthoritativeReplay: Bool,
        snapshotMessageIDs: Set<String>,
        optimisticUserMessageIDs: Set<String>
    ) -> [ChatMessage] {
        guard isLoading, !hasAuthoritativeReplay else {
            return messages
        }

        return messages.filter { message in
            optimisticUserMessageIDs.contains(message.id) || !snapshotMessageIDs.contains(message.id)
        }
    }
}

enum TranscriptBottomScrollPolicy {
    static func shouldRequestAfterInitialSettle(canSettleToBottom: Bool) -> Bool {
        canSettleToBottom
    }

    static func shouldRequestAfterSettleAvailabilityChanged(canSettleToBottom: Bool) -> Bool {
        canSettleToBottom
    }

    static func shouldRequestAfterMessageCountChanged(
        canSettleToBottom: Bool,
        isUserNearBottom: Bool,
        oldCount: Int
    ) -> Bool {
        canSettleToBottom && (isUserNearBottom || oldCount == 0)
    }

    static func shouldRequestAfterLastMessageChanged(
        canSettleToBottom: Bool,
        isUserNearBottom: Bool
    ) -> Bool {
        canSettleToBottom && isUserNearBottom
    }
}

enum TranscriptAssistantProgressPolicy {
    static func shouldShow(
        messages: [ChatMessage],
        optimisticUserMessageIDs: Set<String>,
        isLoading: Bool,
        queuedPromptCount: Int,
        errorMessage: String?
    ) -> Bool {
        guard !isLoading,
              queuedPromptCount == 0,
              errorMessage == nil,
              let message = messages.last,
              message.role == .user,
              optimisticUserMessageIDs.contains(message.id)
        else {
            return false
        }

        return true
    }
}

enum TranscriptAnimationTiming {
    static func duration(_ baseDuration: TimeInterval) -> TimeInterval {
        baseDuration * scale
    }

    static func offset(_ baseOffset: CGFloat) -> CGFloat {
        baseOffset * CGFloat(min(scale, 2))
    }

    private static let scale: TimeInterval = {
        #if DEBUG
        guard let rawValue = ProcessInfo.processInfo.environment["AWAY_TRANSCRIPT_ANIMATION_SCALE"],
              let value = TimeInterval(rawValue)
        else {
            return 1
        }

        return min(max(value, 1), 8)
        #else
        return 1
        #endif
    }()
}

enum TranscriptRowChange: Equatable {
    case unchanged
    case tailAppend(startIndex: Int, count: Int)
    case tailReplacement(startIndex: Int, deletedCount: Int, insertedCount: Int)
    case nonTailChange
}

enum TranscriptAnimationPolicy {
    static func rowChange(
        oldRows: [TranscriptSurfaceRow],
        newRows: [TranscriptSurfaceRow]
    ) -> TranscriptRowChange {
        let oldIDs = oldRows.map(\.id)
        let newIDs = newRows.map(\.id)
        guard oldIDs != newIDs else { return .unchanged }
        guard newIDs.count > oldIDs.count,
              newIDs.starts(with: oldIDs)
        else {
            if let oldLast = oldRows.last,
               oldLast.isAssistantProgress {
                let oldPrefix = oldIDs.dropLast()
                let sharedPrefixCount = oldPrefix.count
                if newIDs.starts(with: oldPrefix), newIDs.count >= sharedPrefixCount {
                    return .tailReplacement(
                        startIndex: sharedPrefixCount,
                        deletedCount: oldIDs.count - sharedPrefixCount,
                        insertedCount: newIDs.count - sharedPrefixCount
                    )
                }
            }
            return .nonTailChange
        }

        return .tailAppend(startIndex: oldIDs.count, count: newIDs.count - oldIDs.count)
    }

    static func shouldAnimateStreamingBottomFollow(
        oldRows: [TranscriptSurfaceRow],
        newRows: [TranscriptSurfaceRow],
        isLoading: Bool,
        wasNearBottom: Bool
    ) -> Bool {
        guard !isLoading,
              wasNearBottom,
              let lastMessage = newRows.last?.message,
              lastMessage.role == .assistant,
              lastMessage.isStreaming
        else {
            return false
        }

        switch rowChange(oldRows: oldRows, newRows: newRows) {
        case .unchanged:
            return oldRows != newRows
        case .tailAppend, .tailReplacement:
            return true
        case .nonTailChange:
            return false
        }
    }

    static func bottomEntranceInsertedRowIDs(
        oldRows: [TranscriptSurfaceRow],
        newRows: [TranscriptSurfaceRow],
        optimisticUserMessageIDs: Set<String>,
        wasNearBottom: Bool
    ) -> Set<String> {
        guard wasNearBottom || oldRows.isEmpty,
              let insertedRows = insertedRowsForBottomEntrance(oldRows: oldRows, newRows: newRows)
        else {
            return []
        }

        return Set(insertedRows.compactMap { row in
            if row.optimisticUserMessageID(optimisticUserMessageIDs) != nil {
                return row.id
            }
            if row.isAssistantProgress || row.containsToolContent {
                guard !oldRows.isEmpty || !row.containsToolContent else {
                    return nil
                }
                return row.id
            }
            return nil
        })
    }

    static func insertedRowsForBottomEntrance(
        oldRows: [TranscriptSurfaceRow],
        newRows: [TranscriptSurfaceRow]
    ) -> ArraySlice<TranscriptSurfaceRow>? {
        switch rowChange(oldRows: oldRows, newRows: newRows) {
        case .tailAppend(let startIndex, let count),
             .tailReplacement(let startIndex, _, let count):
            return newRows[startIndex..<(startIndex + count)]
        case .unchanged, .nonTailChange:
            return nil
        }
    }

    static func newToolContentIDsByRowID(
        oldRows: [TranscriptSurfaceRow],
        newRows: [TranscriptSurfaceRow],
        wasNearBottom: Bool
    ) -> [String: Set<String>] {
        guard wasNearBottom else { return [:] }
        let oldRowsByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })

        return newRows.reduce(into: [:]) { result, row in
            guard let oldRow = oldRowsByID[row.id],
                  let oldMessage = oldRow.message,
                  let newMessage = row.message
            else {
                return
            }

            let oldToolIDs = Set(oldMessage.content.compactMap(\.toolContentID))
            let newToolIDs = Set(newMessage.content.compactMap(\.toolContentID))
            let insertedToolIDs = newToolIDs.subtracting(oldToolIDs)
            if !insertedToolIDs.isEmpty {
                result[row.id] = insertedToolIDs
            }
        }
    }
}

struct TranscriptSurface: View {
    let session: SessionSummary?
    let messages: [ChatMessage]
    let isLoading: Bool
    let hasAuthoritativeReplay: Bool
    let snapshotMessageIDs: Set<String>
    let optimisticUserMessageIDs: Set<String>
    let showsAssistantProgress: Bool
    let earlierMessageCount: Int
    let scrollIntent: TranscriptScrollIntent?
    let onReachTop: () -> Void
    let onNearBottomChanged: (Bool) -> Void

    var body: some View {
        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: messages,
            isLoading: isLoading,
            hasAuthoritativeReplay: hasAuthoritativeReplay,
            snapshotMessageIDs: snapshotMessageIDs,
            optimisticUserMessageIDs: optimisticUserMessageIDs,
            showsAssistantProgress: showsAssistantProgress
        )

        #if os(iOS)
        UIKitTranscriptSurface(
            rows: rows,
            isLoading: isLoading,
            optimisticUserMessageIDs: optimisticUserMessageIDs,
            earlierMessageCount: earlierMessageCount,
            scrollIntent: scrollIntent,
            onReachTop: onReachTop,
            onNearBottomChanged: onNearBottomChanged
        )
        #else
        SwiftUITranscriptSurfaceFallback(
            rows: rows,
            scrollIntent: scrollIntent,
            onNearBottomChanged: onNearBottomChanged
        )
        #endif
    }
}

private extension TranscriptSurfaceRow {
    var message: ChatMessage? {
        if case .message(let message) = self {
            return message
        }
        return nil
    }

    var isAssistantProgress: Bool {
        if case .assistantProgress = self {
            return true
        }
        return false
    }

    var containsToolContent: Bool {
        guard let message else { return false }
        return message.content.contains {
            if case .tool = $0 {
                return true
            }
            return false
        }
    }

    func optimisticUserMessageID(_ optimisticUserMessageIDs: Set<String>) -> String? {
        guard let message,
              message.role == .user,
              optimisticUserMessageIDs.contains(message.id)
        else {
            return nil
        }
        return message.id
    }
}

private extension ChatContent {
    var toolContentID: String? {
        if case .tool(let tool) = self {
            return "tool:\(tool.id)"
        }
        return nil
    }
}

struct TranscriptSurfaceRowView: View {
    let row: TranscriptSurfaceRow
    var animatedContentIDs: Set<String> = []

    var body: some View {
        switch row {
        case .sessionShell(let session):
            ChatSessionShellView(session: session)
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
        case .message(let message):
            MessageBubbleView(message: message, animatedContentIDs: animatedContentIDs)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        case .assistantProgress:
            AssistantProgressRowView()
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
    }
}

private struct AssistantProgressRowView: View {
    var body: some View {
        HStack {
            AssistantProgressView()
            Spacer(minLength: 24)
        }
    }
}

struct ChatSessionShellView: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.displayTitle)
                .font(.headline)
            if let subtitle = session.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let cwd = session.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                if session.messageCount > 0 {
                    Label("\(session.messageCount)", systemImage: "text.bubble")
                }
                if let activityAt = session.activityAt {
                    Text(activityAt, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

private struct SwiftUITranscriptSurfaceFallback: View {
    let rows: [TranscriptSurfaceRow]
    let scrollIntent: TranscriptScrollIntent?
    let onNearBottomChanged: (Bool) -> Void

    var body: some View {
        // Placeholder for future non-iOS targets. A native macOS adapter should implement
        // top reveal and live near-bottom reporting before this path ships.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        TranscriptSurfaceRowView(row: row)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                onNearBottomChanged(true)
                apply(scrollIntent, proxy: proxy)
            }
            .onChange(of: scrollIntent) { _, newValue in
                apply(newValue, proxy: proxy)
            }
        }
    }

    private func apply(_ intent: TranscriptScrollIntent?, proxy: ScrollViewProxy) {
        guard let intent else { return }
        let targetID: String?
        switch intent.target {
        case .message(let id):
            targetID = "message:\(id)"
        case .bottom:
            targetID = rows.last?.id
        }
        guard let targetID else { return }

        let anchor: UnitPoint
        switch intent.anchor {
        case .top:
            anchor = .top
        case .center:
            anchor = .center
        case .bottom:
            anchor = .bottom
        }

        var transaction = Transaction()
        transaction.disablesAnimations = !intent.animated
        withTransaction(transaction) {
            proxy.scrollTo(targetID, anchor: anchor)
        }
    }
}
