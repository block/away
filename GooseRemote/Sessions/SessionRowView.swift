import SwiftUI
import UIKit

struct SessionRowView: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SessionGlyph(isWorking: session.isWorking)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.displayTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let activityAt = session.activityAt {
                        Text(activityAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }

                Text(previewText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                metadataLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var previewText: String {
        let text = nonEmpty(session.subtitle) ?? nonEmpty(session.cwd) ?? "No recent message"
        return String(text.prefix(180))
    }

    private var accessibilityLabel: String {
        var parts = [session.displayTitle, previewText]
        if session.isWorking {
            parts.append("Running")
        }
        if session.messageCount > 0 {
            let noun = session.messageCount == 1 ? "message" : "messages"
            parts.append("\(session.messageCount) \(noun)")
        }
        if let activityAt = session.activityAt {
            parts.append(activityAt.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: ", ")
    }

    private var metadataLine: some View {
        ViewThatFits(in: .horizontal) {
            metadata(spacing: 10, showModel: true)
            metadata(spacing: 8, showModel: false)
        }
    }

    private func metadata(spacing: CGFloat, showModel: Bool) -> some View {
        HStack(spacing: spacing) {
            if session.isWorking {
                Label("Running", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            }

            if session.messageCount > 0 {
                Label("\(session.messageCount)", systemImage: "text.bubble")
            }

            if let cwd = nonEmpty(session.cwd) {
                Label(shortPath(cwd), systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            if showModel, let model = nonEmpty(session.modelID) ?? nonEmpty(session.providerID) {
                Label(model, systemImage: "cpu")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private func shortPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last else { return trimmed }
        if components.count >= 2, let parent = components.dropLast().last {
            return "\(parent)/\(last)"
        }
        return String(last)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct SessionGlyph: View {
    let isWorking: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)

            if isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.green)
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var background: Color {
        isWorking ? Color.green.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground)
    }
}
