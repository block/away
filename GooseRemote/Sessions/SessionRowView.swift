import SwiftUI

struct SessionRowView: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(session.displayTitle)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            if let activityAt = session.activityAt {
                Text(compactRelativeTime(for: activityAt))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel(activityAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let activityAt = session.activityAt else {
            return session.displayTitle
        }
        return "\(session.displayTitle), \(activityAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func compactRelativeTime(for date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        let minute: TimeInterval = 60
        let hour: TimeInterval = minute * 60
        let day: TimeInterval = hour * 24

        switch seconds {
        case 0..<minute:
            return "now"
        case 0..<hour:
            return "\(Int(seconds / minute))m"
        case 0..<day:
            return "\(Int(seconds / hour))h"
        case 0..<(day * 7):
            return "\(Int(seconds / day))d"
        default:
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
