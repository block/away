import Foundation
@preconcurrency import Crypto
import NIOSSH

struct RemoteConnectionConfig: Sendable {
    enum Mode: Sendable {
        case directWebSocket(URL)
        case sshStdio(SSHConfig)
        case sshForwardedWebSocket(SSHConfig, remoteACPURL: URL)
    }

    var mode: Mode
    var defaultCWD: String
    var demoBackgroundKeepaliveEnabled: Bool

    static let demo = demo(
        environment: ProcessInfo.processInfo.environment,
        settingsStore: .standard
    )

    static func demo(environment: [String: String]) -> RemoteConnectionConfig {
        makeDemoConfig(environment: environment)
    }

    static func demo(
        environment: [String: String],
        settingsStore: DemoConnectionSettingsStore
    ) -> RemoteConnectionConfig {
        let mergedEnvironment = settingsStore.environmentByMergingSavedSettings(with: environment)
        let config = makeDemoConfig(environment: mergedEnvironment)
        settingsStore.saveExplicitSettings(from: environment)
        return config
    }

    private static func makeDemoConfig(environment: [String: String]) -> RemoteConnectionConfig {
        let defaultCWD = environment["AWAY_DEFAULT_CWD"] ?? "~"
        let keepaliveEnabled = environment["AWAY_BACKGROUND_KEEPALIVE"] == "1"
        let mode = environment["AWAY_TRANSPORT"].map(normalizeMode) ?? "sshstdio"

        switch mode {
        case "sshstdio":
            return RemoteConnectionConfig(
                mode: .sshStdio(makeSSHConfig(environment: environment)),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        case "sshforwardedwebsocket":
            let rawURL = environment["AWAY_REMOTE_ACP_URL"] ?? defaultDirectWebSocketURL
            guard let remoteACPURL = URL(string: rawURL) else {
                preconditionFailure("AWAY_REMOTE_ACP_URL is invalid: \(rawURL)")
            }
            return RemoteConnectionConfig(
                mode: .sshForwardedWebSocket(makeSSHConfig(environment: environment), remoteACPURL: remoteACPURL),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        case "directwebsocket", "websocket":
            let rawURL = environment["AWAY_ACP_URL"] ?? defaultDirectWebSocketURL
            guard let url = URL(string: rawURL) else {
                preconditionFailure("AWAY_ACP_URL is invalid: \(rawURL)")
            }
            return RemoteConnectionConfig(
                mode: .directWebSocket(url),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        default:
            preconditionFailure("Unsupported AWAY_TRANSPORT: \(environment["AWAY_TRANSPORT"] ?? mode)")
        }
    }

    private static let defaultDirectWebSocketURL = "ws://127.0.0.1:32845/acp?token=local-secret"

    private static func normalizeMode(_ raw: String) -> String {
        raw.filter(\.isLetter).lowercased()
    }

    private static func makeSSHConfig(environment: [String: String]) -> SSHConfig {
        let host = environment["AWAY_SSH_HOST"] ?? "127.0.0.1"
        let port = environment["AWAY_SSH_PORT"].flatMap(Int.init) ?? 22
        let username = environment["AWAY_SSH_USERNAME"] ?? NSUserName()
        let command = environment["AWAY_SSH_COMMAND"] ?? "goose acp"

        return SSHConfig(
            host: host,
            port: port,
            username: username,
            authentication: makeSSHAuthentication(environment: environment),
            command: command
        )
    }

    private static func makeSSHAuthentication(environment: [String: String]) -> SSHAuthentication {
        if let password = environment["AWAY_SSH_PASSWORD"] {
            return .password(password)
        }

        if let pemBase64 = environment["AWAY_SSH_P256_PRIVATE_KEY_PEM_BASE64"] {
            guard let data = Data(base64Encoded: pemBase64),
                  let pem = String(data: data, encoding: .utf8),
                  let key = try? P256.Signing.PrivateKey(pemRepresentation: pem)
            else {
                preconditionFailure("AWAY_SSH_P256_PRIVATE_KEY_PEM_BASE64 is not a valid P-256 PEM key")
            }
            return .privateKey(NIOSSHPrivateKey(p256Key: key))
        }

        if let rawBase64 = environment["AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64"] {
            guard let data = Data(base64Encoded: rawBase64),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: data)
            else {
                preconditionFailure("AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64 is not a valid P-256 raw key")
            }
            return .privateKey(NIOSSHPrivateKey(p256Key: key))
        }

        return .none
    }

    static func directWebSocketURL(_ raw: String) -> URL {
        guard let url = URL(string: raw) else {
            preconditionFailure("Hardcoded demo ACP URL is invalid")
        }
        return url
    }
}

struct SSHConfig: Sendable {
    var host: String
    var port: Int
    var username: String
    var authentication: SSHAuthentication
    var command: String?

    init(
        host: String,
        port: Int = 22,
        username: String,
        authentication: SSHAuthentication,
        command: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.command = command
    }
}

enum SSHAuthentication: Sendable {
    case none
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

struct DemoConnectionSettingsStore: @unchecked Sendable {
    static let standard = DemoConnectionSettingsStore(defaults: .standard)

    private static let prefix = "Away.demoConnection."
    private static let keys = [
        "AWAY_TRANSPORT",
        "AWAY_ACP_URL",
        "AWAY_REMOTE_ACP_URL",
        "AWAY_DEFAULT_CWD",
        "AWAY_BACKGROUND_KEEPALIVE",
        "AWAY_SSH_HOST",
        "AWAY_SSH_PORT",
        "AWAY_SSH_USERNAME",
        "AWAY_SSH_PASSWORD",
        "AWAY_SSH_COMMAND",
        "AWAY_SSH_P256_PRIVATE_KEY_PEM_BASE64",
        "AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64"
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func environmentByMergingSavedSettings(with environment: [String: String]) -> [String: String] {
        var merged = savedSettings()
        for (key, value) in environment where Self.keys.contains(key) {
            merged[key] = value
        }
        if environmentContainsSSHSettings(environment), environment["AWAY_TRANSPORT"] == nil {
            merged["AWAY_TRANSPORT"] = "ssh-stdio"
        }
        return merged
    }

    func saveExplicitSettings(from environment: [String: String]) {
        var hasAnyExplicitSetting = false
        for key in Self.keys {
            guard let value = environment[key] else { continue }
            hasAnyExplicitSetting = true
            defaults.set(value, forKey: storageKey(key))
        }

        if environmentContainsSSHSettings(environment), environment["AWAY_TRANSPORT"] == nil {
            hasAnyExplicitSetting = true
            defaults.set("ssh-stdio", forKey: storageKey("AWAY_TRANSPORT"))
        }

        if hasAnyExplicitSetting {
            defaults.synchronize()
        }
    }

    func clear() {
        for key in Self.keys {
            defaults.removeObject(forKey: storageKey(key))
        }
    }

    private func savedSettings() -> [String: String] {
        var settings: [String: String] = [:]
        for key in Self.keys {
            if let value = defaults.string(forKey: storageKey(key)) {
                settings[key] = value
            }
        }
        return settings
    }

    private func environmentContainsSSHSettings(_ environment: [String: String]) -> Bool {
        environment.keys.contains { key in
            key.hasPrefix("AWAY_SSH_")
        }
    }

    private func storageKey(_ key: String) -> String {
        Self.prefix + key
    }
}
