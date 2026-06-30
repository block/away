@preconcurrency import Crypto
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

    func testDemoConfigDefaultsToSSHStdio() throws {
        let config = try RemoteConnectionConfig.demo(environment: [:])

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
        }
        XCTAssertEqual(config.defaultCWD, "~")
        XCTAssertFalse(config.demoBackgroundKeepaliveEnabled)
    }

    func testDemoConfigRejectsDirectWebSocketEnvironment() {
        XCTAssertThrowsError(
            try RemoteConnectionConfig.demo(environment: [
                "AWAY_TRANSPORT": "direct-websocket"
            ])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Unsupported AWAY_TRANSPORT 'direct-websocket'. SSH stdio is the only supported transport; relaunch with AWAY_TRANSPORT=ssh-stdio."
            )
        }
    }

    func testDemoConfigRejectsInvalidSSHPort() {
        XCTAssertThrowsError(
            try RemoteConnectionConfig.demo(environment: [
                "AWAY_TRANSPORT": "ssh-stdio",
                "AWAY_SSH_PORT": "not-a-port"
            ])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "AWAY_SSH_PORT must be a TCP port from 1 through 65535, not 'not-a-port'."
            )
        }
    }

    func testDemoConfigRejectsOutOfRangeSSHPort() {
        XCTAssertThrowsError(
            try RemoteConnectionConfig.demo(environment: [
                "AWAY_TRANSPORT": "ssh-stdio",
                "AWAY_SSH_PORT": "65536"
            ])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "AWAY_SSH_PORT must be a TCP port from 1 through 65535, not '65536'."
            )
        }
    }

    func testDemoConfigRejectsInvalidRawP256Key() {
        XCTAssertThrowsError(
            try RemoteConnectionConfig.demo(environment: [
                "AWAY_TRANSPORT": "ssh-stdio",
                "AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64": "not-base64"
            ])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64 is not a valid base64-encoded P-256 private key."
            )
        }
    }

    func testDemoConfigRejectsEmptySSHValues() {
        XCTAssertThrowsError(
            try RemoteConnectionConfig.demo(environment: [
                "AWAY_TRANSPORT": "ssh-stdio",
                "AWAY_SSH_COMMAND": "   "
            ])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "AWAY_SSH_COMMAND must not be empty for SSH stdio demo configuration."
            )
        }
    }

    func testDemoConfigReadsSSHStdioEnvironment() throws {
        let config = try RemoteConnectionConfig.demo(environment: [
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
        }
        XCTAssertEqual(config.defaultCWD, "/tmp/project")
        XCTAssertTrue(config.demoBackgroundKeepaliveEnabled)
    }

    func testDemoConfigTrimsStringEnvironmentValues() throws {
        let config = try RemoteConnectionConfig.demo(environment: [
            "AWAY_TRANSPORT": " ssh-stdio ",
            "AWAY_SSH_HOST": " localhost ",
            "AWAY_SSH_PORT": " 2222 ",
            "AWAY_SSH_USERNAME": " demo ",
            "AWAY_SSH_COMMAND": " goose acp ",
            "AWAY_DEFAULT_CWD": " /tmp/project "
        ])

        switch config.mode {
        case .sshStdio(let ssh):
            XCTAssertEqual(ssh.host, "localhost")
            XCTAssertEqual(ssh.port, 2222)
            XCTAssertEqual(ssh.username, "demo")
            XCTAssertEqual(ssh.command, "goose acp")
        }
        XCTAssertEqual(config.defaultCWD, "/tmp/project")
    }

    func testDemoConfigPersistsSSHEnvironmentForManualRelaunch() throws {
        let (suiteName, defaults, store) = try makeIsolatedSettingsStore()
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        _ = try RemoteConnectionConfig.demo(
            environment: [
                "AWAY_SSH_HOST": "127.0.0.1",
                "AWAY_SSH_PORT": "2222",
                "AWAY_SSH_USERNAME": "demo",
                "AWAY_SSH_PASSWORD": "secret",
                "AWAY_SSH_COMMAND": "goose acp"
            ],
            settingsStore: store
        )

        XCTAssertNil(defaults.string(forKey: "Away.demoConnection.AWAY_SSH_PASSWORD"))

        let relaunchedConfig = try RemoteConnectionConfig.demo(
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
        }
    }

    func testDemoConfigPersistsRawP256KeyForManualRelaunch() throws {
        let (suiteName, defaults, store) = try makeIsolatedSettingsStore()
        let rawKey = P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        _ = try RemoteConnectionConfig.demo(
            environment: [
                "AWAY_TRANSPORT": "ssh-stdio",
                "AWAY_SSH_HOST": "127.0.0.1",
                "AWAY_SSH_PORT": "2222",
                "AWAY_SSH_USERNAME": "demo",
                "AWAY_SSH_COMMAND": "goose acp",
                "AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64": rawKey
            ],
            settingsStore: store
        )

        XCTAssertNil(defaults.string(forKey: "Away.demoConnection.AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64"))

        let relaunchedConfig = try RemoteConnectionConfig.demo(
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
            case .privateKey:
                break
            default:
                XCTFail("Expected persisted raw P-256 private key auth")
            }
        }
    }

    func testExplicitPrivateKeyClearsPersistedPasswordSecret() throws {
        let (suiteName, defaults, store) = try makeIsolatedSettingsStore()
        let rawKey = P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        _ = try RemoteConnectionConfig.demo(
            environment: [
                "AWAY_TRANSPORT": "ssh-stdio",
                "AWAY_SSH_PASSWORD": "old-secret"
            ],
            settingsStore: store
        )

        _ = try RemoteConnectionConfig.demo(
            environment: [
                "AWAY_TRANSPORT": "ssh-stdio",
                "AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64": rawKey
            ],
            settingsStore: store
        )

        let relaunchedConfig = try RemoteConnectionConfig.demo(
            environment: [:],
            settingsStore: store
        )

        switch relaunchedConfig.mode {
        case .sshStdio(let ssh):
            switch ssh.authentication {
            case .privateKey:
                break
            default:
                XCTFail("Expected explicit private key to replace persisted password auth")
            }
        }
    }

    func testExplicitAwaySettingsClearPersistedWebSocketURLSettings() throws {
        let (suiteName, defaults, store) = try makeIsolatedSettingsStore()
        defaults.set("direct-websocket", forKey: "Away.demoConnection.AWAY_TRANSPORT")
        defaults.set("ws://127.0.0.1:32845/acp?token=local-secret", forKey: "Away.demoConnection.AWAY_ACP_URL")
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        _ = try RemoteConnectionConfig.demo(
            environment: [
                "AWAY_TRANSPORT": "ssh-stdio",
                "AWAY_SSH_HOST": "127.0.0.1",
                "AWAY_SSH_PORT": "2222",
                "AWAY_SSH_USERNAME": "demo",
                "AWAY_SSH_COMMAND": "goose acp"
            ],
            settingsStore: store
        )

        XCTAssertEqual(defaults.string(forKey: "Away.demoConnection.AWAY_TRANSPORT"), "ssh-stdio")
        XCTAssertNil(defaults.string(forKey: "Away.demoConnection.AWAY_ACP_URL"))

        let relaunchedConfig = try RemoteConnectionConfig.demo(
            environment: [:],
            settingsStore: store
        )
        switch relaunchedConfig.mode {
        case .sshStdio(let ssh):
            XCTAssertEqual(ssh.port, 2222)
        }
    }

    func testStaleUnsupportedTransportFailsWithResetMessageWhenNoCurrentConfigIsProvided() throws {
        let (suiteName, defaults, store) = try makeIsolatedSettingsStore()
        defaults.set("direct-websocket", forKey: "Away.demoConnection.AWAY_TRANSPORT")
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertThrowsError(
            try RemoteConnectionConfig.demo(environment: [:], settingsStore: store)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Unsupported AWAY_TRANSPORT 'direct-websocket'. SSH stdio is the only supported transport; relaunch with AWAY_TRANSPORT=ssh-stdio."
            )
        }
    }

    func testStaleWebSocketURLSettingsFailWithResetMessageAndAreDeduplicated() throws {
        let (suiteName, defaults, store) = try makeIsolatedSettingsStore()
        defaults.set("ws://127.0.0.1:32845/acp?token=saved", forKey: "Away.demoConnection.AWAY_ACP_URL")
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertThrowsError(
            try RemoteConnectionConfig.demo(
                environment: [
                    "AWAY_ACP_URL": "ws://127.0.0.1:32845/acp?token=local-secret",
                    "AWAY_REMOTE_ACP_URL": "ws://127.0.0.1:32846/acp?token=remote-secret"
                ],
                settingsStore: store
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Found unsupported WebSocket demo settings (AWAY_ACP_URL, AWAY_REMOTE_ACP_URL). WebSocket transports were removed; relaunch with AWAY_* SSH stdio settings or reset the simulator app data."
            )
        }
    }

    func testRemoteConnectionProviderBuildsOnlySSHStdioTransport() throws {
        let config = try RemoteConnectionConfig.demo(environment: [
            "AWAY_TRANSPORT": "ssh-stdio"
        ])

        let transport = try RemoteConnectionProvider().makeTransport(config: config)

        XCTAssertTrue(transport is SSHStdioTransport)
    }

    func testSSHConnectionFailureMessageIncludesHostAndPort() {
        let error = SSHTransportError.connectionFailed(
            host: "127.0.0.1",
            port: 2222,
            underlying: "connection refused"
        )

        XCTAssertEqual(
            error.localizedDescription,
            "SSH stdio failed to connect to 127.0.0.1:2222. Check AWAY_SSH_HOST, AWAY_SSH_PORT, and that the local sshd is running. Underlying error: connection refused"
        )
    }

    @MainActor
    func testAppModelReportsStartupConfigurationFailure() async {
        let model = AppModel(
            connectionConfigResult: .failure(.unsupportedTransport(value: "direct-websocket"))
        )

        await model.connect()

        XCTAssertEqual(
            model.connectionState,
            .failed("Unsupported AWAY_TRANSPORT 'direct-websocket'. SSH stdio is the only supported transport; relaunch with AWAY_TRANSPORT=ssh-stdio.")
        )
        XCTAssertEqual(
            model.errorMessage,
            "Unsupported AWAY_TRANSPORT 'direct-websocket'. SSH stdio is the only supported transport; relaunch with AWAY_TRANSPORT=ssh-stdio."
        )
    }

    @MainActor
    func testAppModelResultSuccessPropagatesDemoKeepaliveSetting() {
        let config = RemoteConnectionConfig(
            mode: .sshStdio(
                SSHConfig(
                    host: "127.0.0.1",
                    port: 2222,
                    username: "demo",
                    authentication: .none,
                    command: "goose acp"
                )
            ),
            defaultCWD: "~",
            demoBackgroundKeepaliveEnabled: true
        )

        let model = AppModel(connectionConfigResult: .success(config))

        XCTAssertTrue(model.demoBackgroundKeepaliveEnabled)
    }

    func testDemoResultSuccessWrapsParsedConfig() throws {
        let (suiteName, defaults, store) = try makeIsolatedSettingsStore()
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let result = RemoteConnectionConfig.demoResult(
            environment: ["AWAY_BACKGROUND_KEEPALIVE": "1"],
            settingsStore: store
        )

        switch result {
        case .success(let config):
            XCTAssertTrue(config.demoBackgroundKeepaliveEnabled)
        case .failure(let error):
            XCTFail("Expected parsed config, got \(error)")
        }
    }

    private func makeIsolatedSettingsStore() throws -> (
        suiteName: String,
        defaults: UserDefaults,
        store: DemoConnectionSettingsStore
    ) {
        let suiteName = "AwayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = DemoConnectionSettingsStore(
            defaults: defaults,
            keychainService: suiteName
        )
        return (suiteName, defaults, store)
    }
}
