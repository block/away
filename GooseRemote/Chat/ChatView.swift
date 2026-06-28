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

            ChatTranscriptView(
                session: session,
                messages: messages,
                isLoading: isLoading,
                hasTailSnapshot: runtime.hasTailSnapshot,
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

private struct ChatTranscriptView: View {
    let session: SessionSummary?
    let messages: [ChatMessage]
    let isLoading: Bool
    let hasTailSnapshot: Bool
    let earlierMessageCount: Int
    let onRevealEarlierMessages: () -> Void

    @State private var isUserNearBottom = true
    @State private var bottomScrollSequence = 0

    private var canSettleToBottom: Bool {
        !isLoading || hasTailSnapshot
    }

    var body: some View {
        TranscriptSurface(
            session: session,
            messages: messages,
            isLoading: isLoading,
            earlierMessageCount: earlierMessageCount,
            scrollIntent: scrollIntent,
            onReachTop: {
                guard earlierMessageCount > 0 else { return }
                onRevealEarlierMessages()
            },
            onNearBottomChanged: { isNearBottom in
                isUserNearBottom = isNearBottom
            }
        )
        .onAppear {
            if TranscriptBottomScrollPolicy.shouldRequestAfterInitialSettle(canSettleToBottom: canSettleToBottom) {
                requestBottomScroll()
            }
        }
        .onChange(of: canSettleToBottom) { _, newValue in
            guard TranscriptBottomScrollPolicy.shouldRequestAfterSettleAvailabilityChanged(canSettleToBottom: newValue) else {
                return
            }
            requestBottomScroll()
        }
        .onChange(of: messages.count) { oldValue, _ in
            guard TranscriptBottomScrollPolicy.shouldRequestAfterMessageCountChanged(
                canSettleToBottom: canSettleToBottom,
                isUserNearBottom: isUserNearBottom,
                oldCount: oldValue
            ) else {
                return
            }
            requestBottomScroll()
        }
        .onChange(of: messages.last?.id) { _, _ in
            guard TranscriptBottomScrollPolicy.shouldRequestAfterLastMessageChanged(
                canSettleToBottom: canSettleToBottom,
                isUserNearBottom: isUserNearBottom
            ) else {
                return
            }
            requestBottomScroll()
        }
    }

    private var scrollIntent: TranscriptScrollIntent? {
        guard bottomScrollSequence > 0 else { return nil }
        return TranscriptScrollIntent(
            target: .bottom,
            anchor: .bottom,
            animated: false,
            sequence: bottomScrollSequence
        )
    }

    private func requestBottomScroll() {
        bottomScrollSequence += 1
    }
}
