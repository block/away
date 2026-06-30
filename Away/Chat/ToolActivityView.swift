import SwiftUI

struct ToolActivityView: View {
    let tool: ToolActivity

    var body: some View {
        ToolActivityStepView(
            step: ToolActivityStep(
                id: tool.id,
                groupID: nil,
                tool: tool,
                isLastInGroup: true
            )
        )
    }
}

struct ToolActivityGroupView: View {
    let group: ToolActivityGroup
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                ToolStatusSymbol(status: group.aggregateStatus)

                SlidingToolGroupTitleText(text: group.compactTitle)

                ToolGroupCountPill(count: group.countBadgeText)

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.title)
        .accessibilityValue(group.isExpanded ? "Expanded" : "Collapsed")
        .animation(.snappy(duration: 0.22), value: group.isExpanded)
        .animation(.snappy(duration: 0.22), value: group.title)
    }
}

private struct SlidingToolGroupTitleText: View {
    let text: String

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .id(text)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
        }
        .clipped()
    }
}

private struct ToolGroupCountPill: View {
    let count: String

    var body: some View {
        Text(count)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .contentTransition(.numericText())
            .frame(minWidth: 20, minHeight: 18)
            .padding(.horizontal, 5)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.14))
            )
            .overlay(
                Capsule()
                    .stroke(Color.secondary.opacity(0.10), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
            .animation(.snappy(duration: 0.22), value: count)
    }
}

struct ToolActivityStepView: View {
    let step: ToolActivityStep

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if step.groupID != nil {
                ToolStepRail(status: step.tool.status, isLast: step.isLastInGroup)
            } else {
                ToolStatusSymbol(status: step.tool.status)
                    .frame(width: 16, height: 18)
            }

            Text(step.tool.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)

            Spacer(minLength: 8)

            if step.tool.isActive {
                Text(statusText(step.tool.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.22), value: step.tool.displayName)
        .animation(.snappy(duration: 0.22), value: step.tool.status)
    }

    private func statusText(_ status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ")
    }
}

private struct ToolStepRail: View {
    let status: String
    let isLast: Bool

    var body: some View {
        ZStack(alignment: .top) {
            if !isLast {
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 12)
            }
            ToolStatusSymbol(status: status)
                .frame(width: 16, height: 18)
        }
        .frame(width: 16, height: 22)
    }
}

private struct ToolStatusSymbol: View {
    let status: String

    var body: some View {
        Image(systemName: iconName)
            .font(.caption)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        switch status {
        case "completed":
            "checkmark.circle.fill"
        case "failed":
            "xmark.circle.fill"
        case "stopped":
            "minus.circle.fill"
        case "pending":
            "circle"
        default:
            "clock"
        }
    }

    private var iconColor: Color {
        switch status {
        case "completed":
            .secondary
        case "failed":
            .red
        case "stopped":
            .orange
        default:
            .secondary
        }
    }
}
