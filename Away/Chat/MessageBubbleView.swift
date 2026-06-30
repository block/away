import Foundation
import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    var animatedContentIDs: Set<String> = []

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, content in
                    contentView(content)
                        .modifier(
                            BottomEntranceModifier(
                                enabled: animatedContentIDs.contains(content.id)
                            )
                        )
                }
                if message.isStreaming, message.content.isEmpty {
                    AssistantProgressView()
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

struct AssistantProgressView: View {
    @State private var shimmerPhase: CGFloat = -0.8

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            shimmeringText
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .onAppear {
            shimmerPhase = -0.8
            withAnimation(
                .linear(duration: TranscriptAnimationTiming.duration(1.15))
                    .repeatForever(autoreverses: false)
            ) {
                shimmerPhase = 1.2
            }
        }
    }

    private var shimmeringText: some View {
        Text("Thinking...")
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.primary.opacity(0.32),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(
                        width: max(40, geometry.size.width * 0.65),
                        height: geometry.size.height
                    )
                    .offset(x: shimmerPhase * geometry.size.width)
                }
                .mask(alignment: .leading) {
                    Text("Thinking...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
    }
}

private struct BottomEntranceModifier: ViewModifier {
    let enabled: Bool
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(enabled && !isVisible ? 0 : 1)
            .offset(y: enabled && !isVisible ? TranscriptAnimationTiming.offset(22) : 0)
            .onAppear {
                guard enabled else { return }
                withAnimation(.easeOut(duration: TranscriptAnimationTiming.duration(0.24))) {
                    isVisible = true
                }
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
