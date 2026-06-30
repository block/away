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
            ZStack(alignment: .top) {
                ChatTranscriptView(
                    session: session,
                    messages: messages,
                    isLoading: isLoading,
                    hasAuthoritativeReplay: runtime.hasAuthoritativeReplay,
                    snapshotMessageIDs: runtime.snapshotMessageIDs,
                    optimisticUserMessageIDs: runtime.optimisticUserMessageIDs,
                    earlierMessageCount: earlierMessageCount
                ) {
                    model.revealEarlierMessages(for: sessionID)
                }

                if isLoading {
                    LoadingSessionBadge()
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .transaction { transaction in
                            transaction.disablesAnimations = true
                        }
                }
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
    let hasAuthoritativeReplay: Bool
    let snapshotMessageIDs: Set<String>
    let optimisticUserMessageIDs: Set<String>
    let earlierMessageCount: Int
    let onRevealEarlierMessages: () -> Void

    @State private var isUserNearBottom = true
    @State private var bottomScrollSequence = 0

    private var canSettleToBottom: Bool {
        !isLoading || hasAuthoritativeReplay
    }

    private var canRevealEarlierMessages: Bool {
        !isLoading || hasAuthoritativeReplay
    }

    var body: some View {
        TranscriptSurface(
            session: session,
            messages: messages,
            isLoading: isLoading,
            hasAuthoritativeReplay: hasAuthoritativeReplay,
            snapshotMessageIDs: snapshotMessageIDs,
            optimisticUserMessageIDs: optimisticUserMessageIDs,
            earlierMessageCount: canRevealEarlierMessages ? earlierMessageCount : 0,
            scrollIntent: scrollIntent,
            onReachTop: {
                guard canRevealEarlierMessages, earlierMessageCount > 0 else { return }
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

private struct LoadingSessionBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text("Loading session")
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
