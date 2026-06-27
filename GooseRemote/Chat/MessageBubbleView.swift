import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.content) { content in
                    contentView(content)
                }
                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, message.role == .user ? 14 : 0)
            .padding(.vertical, message.role == .user ? 10 : 2)
            .background(message.role == .user ? Color.accentColor.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: message.role == .user ? 310 : .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user {
                Spacer(minLength: 24)
            }
        }
        .animation(.snappy(duration: 0.18), value: message)
    }

    @ViewBuilder
    private func contentView(_ content: ChatContent) -> some View {
        switch content {
        case .text(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        case .image:
            Label("Image output", systemImage: "photo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .tool(let tool):
            ToolActivityView(tool: tool)
        case .system(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
