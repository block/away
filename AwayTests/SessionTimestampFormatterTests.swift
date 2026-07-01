import XCTest
@testable import Away

final class SessionTimestampFormatterTests: XCTestCase {
    func testCompactRelativeTimeBoundaries() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertEqual(SessionTimestampFormatter.compactRelativeTime(for: now.addingTimeInterval(-59), relativeTo: now), "now")
        XCTAssertEqual(SessionTimestampFormatter.compactRelativeTime(for: now.addingTimeInterval(-60), relativeTo: now), "1m")
        XCTAssertEqual(SessionTimestampFormatter.compactRelativeTime(for: now.addingTimeInterval(-3_599), relativeTo: now), "59m")
        XCTAssertEqual(SessionTimestampFormatter.compactRelativeTime(for: now.addingTimeInterval(-3_600), relativeTo: now), "1h")
        XCTAssertEqual(SessionTimestampFormatter.compactRelativeTime(for: now.addingTimeInterval(-86_399), relativeTo: now), "23h")
        XCTAssertEqual(SessionTimestampFormatter.compactRelativeTime(for: now.addingTimeInterval(-86_400), relativeTo: now), "1d")
        XCTAssertEqual(SessionTimestampFormatter.compactRelativeTime(for: now.addingTimeInterval(-604_799), relativeTo: now), "6d")
        XCTAssertNotEqual(SessionTimestampFormatter.compactRelativeTime(for: now.addingTimeInterval(-604_800), relativeTo: now), "7d")
        XCTAssertEqual(SessionTimestampFormatter.compactRelativeTime(for: now.addingTimeInterval(60), relativeTo: now), "now")
    }
}
