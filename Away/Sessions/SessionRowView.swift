import SwiftUI

struct SessionRowView: View {
    let session: SessionSummary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            rowContent(relativeTo: context.date)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func rowContent(relativeTo now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(session.displayTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            if let activityAt = session.activityAt {
                Text(SessionTimestampFormatter.compactRelativeTime(for: activityAt, relativeTo: now))
                    .font(.body.weight(.regular))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel(activityAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityLabel: String {
        guard let activityAt = session.activityAt else {
            return session.displayTitle
        }
        return "\(session.displayTitle), \(activityAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
