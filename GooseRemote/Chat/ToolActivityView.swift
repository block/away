import SwiftUI

struct ToolActivityView: View {
    let tool: ToolActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                Text(tool.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(tool.status.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let result = tool.result, !result.isEmpty {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var iconName: String {
        switch tool.status {
        case "completed":
            "checkmark.circle.fill"
        case "failed":
            "xmark.circle.fill"
        default:
            "hammer.circle"
        }
    }

    private var iconColor: Color {
        switch tool.status {
        case "completed":
            .green
        case "failed":
            .red
        default:
            .orange
        }
    }
}
