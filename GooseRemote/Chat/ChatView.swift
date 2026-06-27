import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        @Bindable var model = model
        let session = model.sessions.first { $0.id == sessionID }
        let messages = model.messagesBySession[sessionID] ?? []
        let runtime = model.runtimeBySession[sessionID] ?? SessionRuntime()

        VStack(spacing: 0) {
            if runtime.isReplaying {
                ProgressView("Loading transcript")
                    .font(.caption)
                    .padding(.vertical, 8)
            }

            MessageTimelineView(messages: messages, isReplaying: runtime.isReplaying)

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
                isSteering: runtime.activeRunID != nil
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
    let messages: [ChatMessage]
    let isReplaying: Bool
    @State private var isNearBottom = true

    private let bottomID = "goose-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                return visibleBottom >= geometry.contentSize.height - 96
            } action: { _, newValue in
                isNearBottom = newValue
            }
            .onChange(of: messages) { _, _ in
                guard !isReplaying, isNearBottom else { return }
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: isReplaying) { _, newValue in
                guard !newValue else { return }
                scrollToBottom(proxy, animated: false)
            }
            .task {
                await Task.yield()
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.snappy(duration: 0.24)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}
