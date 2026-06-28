import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        @Bindable var model = model
        let session = model.sessions.first { $0.id == sessionID }
        let messages = model.messagesBySession[sessionID] ?? []
        let runtime = model.runtimeBySession[sessionID] ?? SessionRuntime()
        let earlierMessageCount = model.earlierMessagesBySession[sessionID]?.count ?? 0
        let isLoading = runtime.isOpening || runtime.isReplaying

        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading session")
                    .font(.caption)
                    .padding(.vertical, 8)
            }

            MessageTimelineView(
                session: session,
                messages: messages,
                isLoading: isLoading,
                earlierMessageCount: earlierMessageCount
            ) {
                model.revealEarlierMessages(for: sessionID)
            }

            if let error = runtime.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }

            ComposerView(
                text: Binding(
                    get: { model.draftBySession[sessionID] ?? "" },
                    set: { model.draftBySession[sessionID] = $0 }
                ),
                isSteering: runtime.activeRunID != nil,
                statusLabel: runtime.queuedPromptCount > 0 ? "Sending when connected" : nil
            ) {
                Task { await model.sendDraft(for: sessionID) }
            }
        }
        .navigationTitle(session?.displayTitle ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if runtime.activeRunID != nil {
                    Label("Running", systemImage: "dot.radiowaves.left.and.right")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                }
            }
        }
        .task(id: sessionID) {
            await model.openSession(sessionID)
        }
    }
}

private struct MessageTimelineView: View {
    let session: SessionSummary?
    let messages: [ChatMessage]
    let isLoading: Bool
    let earlierMessageCount: Int
    let onRevealEarlierMessages: () -> Void
    @State private var isNearBottom = true

    private let bottomID = "goose-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let session, messages.isEmpty, isLoading {
                        ChatSessionShellView(session: session)
                    }

                    if earlierMessageCount > 0 {
                        Button(action: onRevealEarlierMessages) {
                            Label("\(earlierMessageCount) earlier messages", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    }

                    ForEach(messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                return visibleBottom >= geometry.contentSize.height - 96
            } action: { _, newValue in
                isNearBottom = newValue
            }
            .onChange(of: messages) { _, _ in
                guard !isLoading, isNearBottom else { return }
                scrollToBottom(proxy)
            }
            .onChange(of: isLoading) { _, newValue in
                guard !newValue else { return }
                scrollToBottom(proxy)
            }
            .task {
                await Task.yield()
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomID, anchor: .bottom)
    }
}

private struct ChatSessionShellView: View {
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
