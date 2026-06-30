import Foundation
import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, content in
                    contentView(content)
                }
                if message.isStreaming, message.content.isEmpty {
                    Text("Working...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, message.role == .user ? 14 : 0)
            .padding(.vertical, message.role == .user ? 10 : 2)
            .modifier(UserBubbleChrome(isUser: message.role == .user))
            .frame(maxWidth: message.role == .user ? 310 : .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user {
                Spacer(minLength: 24)
            }
        }
    }

    @ViewBuilder
    private func contentView(_ content: ChatContent) -> some View {
        switch content {
        case .text(let text):
            TranscriptTextView(text: text)
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

private struct UserBubbleChrome: ViewModifier {
    let isUser: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isUser {
            content
                .background(Color.accentColor.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content
        }
    }
}

private struct TranscriptTextView: View {
    let text: String

    private let renderLimit = 12_000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(attributedDisplayText)
                .font(.body)
                .textSelection(.enabled)

            if isTruncated {
                Text("Long message truncated for the prototype.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isTruncated: Bool {
        text.count > renderLimit
    }

    private var displayText: String {
        guard isTruncated else { return text }
        return String(text.prefix(renderLimit))
    }

    private var attributedDisplayText: AttributedString {
        TranscriptAttributedTextCache.shared.attributedText(for: displayText)
    }
}

private final class TranscriptAttributedTextCache: @unchecked Sendable {
    static let shared = TranscriptAttributedTextCache()

    private let cache = NSCache<NSString, CachedTranscriptAttributedText>()

    private init() {
        cache.countLimit = 300
    }

    func attributedText(for text: String) -> AttributedString {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }

        let parsed = Self.parse(text)
        cache.setObject(CachedTranscriptAttributedText(parsed), forKey: key)
        return parsed
    }

    private static func parse(_ text: String) -> AttributedString {
        (
            try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        ) ?? AttributedString(text)
    }
}

private final class CachedTranscriptAttributedText {
    let value: AttributedString

    init(_ value: AttributedString) {
        self.value = value
    }
}
