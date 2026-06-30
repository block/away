import SwiftUI

struct SessionRowView: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let activityAt = session.activityAt {
                    Text(activityAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if session.isWorking {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(session.subtitle ?? session.cwd ?? "No recent message")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
