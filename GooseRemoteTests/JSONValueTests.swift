import XCTest
@testable import GooseRemote

final class JSONValueTests: XCTestCase {
    func testDecodesSessionListShape() throws {
        let data = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "sessions": [
              {
                "sessionId": "s1",
                "title": "Demo",
                "cwd": "/tmp/project",
                "_meta": {
                  "messageCount": 3,
                  "lastMessageSnippet": "hello"
                }
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(ACPEnvelope.self, from: data)
        let session = envelope.result?["sessions"]?.arrayValue?.first.flatMap(SessionSummary.init(json:))

        XCTAssertEqual(envelope.id, 1)
        XCTAssertEqual(session?.id, "s1")
        XCTAssertEqual(session?.subtitle, "hello")
        XCTAssertEqual(session?.messageCount, 3)
    }

    func testDemoConfigDefaultsToSSHStdio() {
        let config = RemoteConnectionConfig.demo(environment: [:])

        switch config.mode {
        case .sshStdio(let ssh):
            XCTAssertEqual(ssh.host, "127.0.0.1")
            XCTAssertEqual(ssh.port, 22)
            XCTAssertEqual(ssh.username, NSUserName())
            XCTAssertEqual(ssh.command, "goose acp")
            switch ssh.authentication {
            case .none:
                break
            default:
                XCTFail("Expected no default SSH authentication")
            }
        default:
            XCTFail("Expected SSH stdio mode")
        }
        XCTAssertEqual(config.defaultCWD, "~")
        XCTAssertFalse(config.demoBackgroundKeepaliveEnabled)
    }

    func testDemoConfigReadsDirectWebSocketEnvironment() {
        let config = RemoteConnectionConfig.demo(environment: [
            "GOOSE_REMOTE_TRANSPORT": "direct-websocket",
            "GOOSE_REMOTE_ACP_URL": "ws://example.local:32845/acp?token=test"
        ])

        switch config.mode {
        case .directWebSocket(let url):
            XCTAssertEqual(url.absoluteString, "ws://example.local:32845/acp?token=test")
        default:
            XCTFail("Expected direct WebSocket mode")
        }
    }

    func testDemoConfigReadsSSHStdioEnvironment() {
        let config = RemoteConnectionConfig.demo(environment: [
            "GOOSE_REMOTE_TRANSPORT": "ssh-stdio",
            "GOOSE_REMOTE_SSH_HOST": "localhost",
            "GOOSE_REMOTE_SSH_PORT": "2222",
            "GOOSE_REMOTE_SSH_USERNAME": "demo",
            "GOOSE_REMOTE_SSH_PASSWORD": "secret",
            "GOOSE_REMOTE_SSH_COMMAND": "goose acp",
            "GOOSE_REMOTE_DEFAULT_CWD": "/tmp/project",
            "GOOSE_REMOTE_BACKGROUND_KEEPALIVE": "1"
        ])

        switch config.mode {
        case .sshStdio(let ssh):
            XCTAssertEqual(ssh.host, "localhost")
            XCTAssertEqual(ssh.port, 2222)
            XCTAssertEqual(ssh.username, "demo")
            XCTAssertEqual(ssh.command, "goose acp")
            switch ssh.authentication {
            case .password(let password):
                XCTAssertEqual(password, "secret")
            default:
                XCTFail("Expected password auth")
            }
        default:
            XCTFail("Expected SSH stdio mode")
        }
        XCTAssertEqual(config.defaultCWD, "/tmp/project")
        XCTAssertTrue(config.demoBackgroundKeepaliveEnabled)
    }
}
