import XCTest
@testable import Away

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
            "AWAY_TRANSPORT": "direct-websocket",
            "AWAY_ACP_URL": "ws://example.local:32845/acp?token=test"
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
            "AWAY_TRANSPORT": "ssh-stdio",
            "AWAY_SSH_HOST": "localhost",
            "AWAY_SSH_PORT": "2222",
            "AWAY_SSH_USERNAME": "demo",
            "AWAY_SSH_PASSWORD": "secret",
            "AWAY_SSH_COMMAND": "goose acp",
            "AWAY_DEFAULT_CWD": "/tmp/project",
            "AWAY_BACKGROUND_KEEPALIVE": "1"
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

    func testDemoConfigPersistsSSHEnvironmentForManualRelaunch() throws {
        let suiteName = "AwayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = DemoConnectionSettingsStore(defaults: defaults)
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        _ = RemoteConnectionConfig.demo(
            environment: [
                "AWAY_SSH_HOST": "127.0.0.1",
                "AWAY_SSH_PORT": "2222",
                "AWAY_SSH_USERNAME": "demo",
                "AWAY_SSH_PASSWORD": "secret",
                "AWAY_SSH_COMMAND": "goose acp"
            ],
            settingsStore: store
        )

        let relaunchedConfig = RemoteConnectionConfig.demo(
            environment: [:],
            settingsStore: store
        )

        switch relaunchedConfig.mode {
        case .sshStdio(let ssh):
            XCTAssertEqual(ssh.host, "127.0.0.1")
            XCTAssertEqual(ssh.port, 2222)
            XCTAssertEqual(ssh.username, "demo")
            XCTAssertEqual(ssh.command, "goose acp")
            switch ssh.authentication {
            case .password(let password):
                XCTAssertEqual(password, "secret")
            default:
                XCTFail("Expected persisted password auth")
            }
        default:
            XCTFail("Expected persisted SSH stdio mode")
        }
    }
}
