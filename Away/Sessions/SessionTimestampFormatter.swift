import Foundation

enum SessionTimestampFormatter {
    static func compactRelativeTime(for date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
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
