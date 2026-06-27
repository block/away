import XCTest
@testable import GooseRemote

final class SSHForwardedWebSocketEndpointTests: XCTestCase {
    func testLocalURLPreservesPathAndQuery() throws {
        let endpoint = try SSHForwardedWebSocketEndpoint(
            remoteACPURL: try XCTUnwrap(URL(string: "ws://demo.example.com:32845/acp?token=abc"))
        )

        let localURL = try endpoint.localURL(localPort: 49152)

        XCTAssertEqual(endpoint.remoteHost, "demo.example.com")
        XCTAssertEqual(endpoint.remotePort, 32845)
        XCTAssertEqual(localURL.absoluteString, "ws://127.0.0.1:49152/acp?token=abc")
    }

    func testRejectsTLSSchemeForLocalForwardedDemoPath() {
        XCTAssertThrowsError(
            try SSHForwardedWebSocketEndpoint(
                remoteACPURL: try XCTUnwrap(URL(string: "wss://demo.example.com:443/acp"))
            )
        )
    }
}
