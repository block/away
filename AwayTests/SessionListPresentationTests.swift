import XCTest
@testable import Away

final class SessionListPresentationTests: XCTestCase {
    func testFailedConnectionShowsFailureViewWithoutDuplicateConnectionLine() {
        let state = AppModel.ConnectionState.failed("Connection failed")

        XCTAssertTrue(SessionListPresentation.shouldShowFailureView(connectionState: state))
        XCTAssertFalse(SessionListPresentation.shouldShowConnectionLine(connectionState: state, isKeepaliveEnabled: false))
    }

    func testConnectedConnectionLineOnlyShowsWhenKeepaliveIsEnabled() {
        XCTAssertFalse(
            SessionListPresentation.shouldShowConnectionLine(
                connectionState: .connected,
                isKeepaliveEnabled: false
            )
        )
        XCTAssertTrue(
            SessionListPresentation.shouldShowConnectionLine(
                connectionState: .connected,
                isKeepaliveEnabled: true
            )
        )
    }
}
