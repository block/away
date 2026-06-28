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

    var id: String {
        switch self {
        case .sessionShell(let session):
            "session-shell:\(session.id)"
        case .message(let message):
            "message:\(message.id)"
        }
    }
}

enum TranscriptSurfaceRows {
    static func make(
        session: SessionSummary?,
        messages: [ChatMessage],
        isLoading: Bool
    ) -> [TranscriptSurfaceRow] {
        if let session, messages.isEmpty, isLoading {
            return [.sessionShell(session)]
        }

        return messages.map(TranscriptSurfaceRow.message)
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

struct TranscriptSurface: View {
    let session: SessionSummary?
    let messages: [ChatMessage]
    let isLoading: Bool
    let earlierMessageCount: Int
    let scrollIntent: TranscriptScrollIntent?
    let onReachTop: () -> Void
    let onNearBottomChanged: (Bool) -> Void

    var body: some View {
        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: messages,
            isLoading: isLoading
        )

        #if os(iOS)
        UIKitTranscriptSurface(
            rows: rows,
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

struct TranscriptSurfaceRowView: View {
    let row: TranscriptSurfaceRow

    var body: some View {
        switch row {
        case .sessionShell(let session):
            ChatSessionShellView(session: session)
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
        case .message(let message):
            MessageBubbleView(message: message)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
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
