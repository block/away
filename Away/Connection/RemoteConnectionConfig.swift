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

    static let demoResult = demoResult(
        environment: ProcessInfo.processInfo.environment,
        settingsStore: .standard
    )

    static var demo: RemoteConnectionConfig {
        do {
            return try demoResult.get()
        } catch {
            preconditionFailure(error.localizedDescription)
        }
    }

    static func demo(environment: [String: String]) throws -> RemoteConnectionConfig {
        try makeDemoConfig(environment: environment)
    }

    static func demo(
        environment: [String: String],
        settingsStore: DemoConnectionSettingsStore
    ) throws -> RemoteConnectionConfig {
        let mergedEnvironment = settingsStore.environmentByMergingSavedSettings(with: environment)
        let config = try makeDemoConfig(environment: mergedEnvironment)
        settingsStore.saveExplicitSettings(from: environment)
        return config
    }

    static func demoResult(
        environment: [String: String],
        settingsStore: DemoConnectionSettingsStore
    ) -> Result<RemoteConnectionConfig, RemoteConnectionConfigError> {
        do {
            return .success(try demo(environment: environment, settingsStore: settingsStore))
        } catch let error as RemoteConnectionConfigError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected demo connection config error: \(error.localizedDescription)")
        }
    }

    private static func makeDemoConfig(environment: [String: String]) throws -> RemoteConnectionConfig {
        let defaultCWD = normalizedString(environment["AWAY_DEFAULT_CWD"]) ?? "~"
        let keepaliveEnabled = environment["AWAY_BACKGROUND_KEEPALIVE"] == "1"
        let mode = environment["AWAY_TRANSPORT"].map(normalizeMode) ?? "directwebsocket"

        switch mode {
        case "sshstdio":
            return RemoteConnectionConfig(
                mode: .sshStdio(try makeSSHConfig(environment: environment)),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        case "sshforwardedwebsocket":
            let rawURL = normalizedString(environment["AWAY_REMOTE_ACP_URL"]) ?? defaultDirectWebSocketURL
            let remoteACPURL = try makeURL(rawURL, key: "AWAY_REMOTE_ACP_URL")
            return RemoteConnectionConfig(
                mode: .sshForwardedWebSocket(try makeSSHConfig(environment: environment), remoteACPURL: remoteACPURL),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        case "directwebsocket", "websocket":
            let awayURL = normalizedString(environment["AWAY_ACP_URL"])
            let gooseServeURL = normalizedString(environment["GOOSE_SERVE_URL"])
            let rawURL = awayURL ?? gooseServeURL ?? defaultDirectWebSocketURL
            let urlKey = awayURL != nil ? "AWAY_ACP_URL" : (gooseServeURL != nil ? "GOOSE_SERVE_URL" : "AWAY_ACP_URL")
            let url = try makeURL(rawURL, key: urlKey)
            return RemoteConnectionConfig(
                mode: .directWebSocket(url),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        default:
            throw RemoteConnectionConfigError.unsupportedTransport(environment["AWAY_TRANSPORT"] ?? mode)
        }
    }

    private static let defaultDirectWebSocketURL = "ws://127.0.0.1:32845/acp?token=local-secret"

    private static func normalizeMode(_ raw: String) -> String {
        raw.filter(\.isLetter).lowercased()
    }

    private static func makeSSHConfig(environment: [String: String]) throws -> SSHConfig {
        let host = normalizedString(environment["AWAY_SSH_HOST"]) ?? "127.0.0.1"
        let port = try makePort(environment["AWAY_SSH_PORT"])
        let username = normalizedString(environment["AWAY_SSH_USERNAME"]) ?? NSUserName()
        let command = normalizedString(environment["AWAY_SSH_COMMAND"]) ?? "goose acp"

        return SSHConfig(
            host: host,
            port: port,
            username: username,
            authentication: try makeSSHAuthentication(environment: environment),
            command: command
        )
    }

    private static func makeSSHAuthentication(environment: [String: String]) throws -> SSHAuthentication {
        if let password = normalizedString(environment["AWAY_SSH_PASSWORD"]) {
            return .password(password)
        }

        if let pemBase64 = normalizedString(environment["AWAY_SSH_P256_PRIVATE_KEY_PEM_BASE64"]) {
            guard let data = Data(base64Encoded: pemBase64),
                  let pem = String(data: data, encoding: .utf8),
                  let key = try? P256.Signing.PrivateKey(pemRepresentation: pem)
            else {
                throw RemoteConnectionConfigError.invalidP256PrivateKey("AWAY_SSH_P256_PRIVATE_KEY_PEM_BASE64")
            }
            return .privateKey(NIOSSHPrivateKey(p256Key: key))
        }

        if let rawBase64 = normalizedString(environment["AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64"]) {
            guard let data = Data(base64Encoded: rawBase64),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: data)
            else {
                throw RemoteConnectionConfigError.invalidP256PrivateKey("AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64")
            }
            return .privateKey(NIOSSHPrivateKey(p256Key: key))
        }

        return .none
    }

    private static func makeURL(_ raw: String, key: String) throws -> URL {
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw RemoteConnectionConfigError.invalidURL(key: key, value: raw)
        }
        return url
    }

    private static func makePort(_ raw: String?) throws -> Int {
        guard let raw = normalizedString(raw) else { return 22 }
        guard let port = Int(raw), (1...65535).contains(port) else {
            throw RemoteConnectionConfigError.invalidPort(raw)
        }
        return port
    }

    private static func normalizedString(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func directWebSocketURL(_ raw: String) -> URL {
        guard let url = URL(string: raw) else {
            preconditionFailure("Hardcoded demo ACP URL is invalid")
        }
        return url
    }
}

enum RemoteConnectionConfigError: LocalizedError, Equatable, Sendable {
    case unsupportedTransport(String)
    case invalidURL(key: String, value: String)
    case invalidPort(String)
    case invalidP256PrivateKey(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTransport(let value):
            "Unsupported AWAY_TRANSPORT: \(value). Use direct-websocket, websocket, ssh-stdio, or ssh-forwarded-websocket."
        case .invalidURL(let key, let value):
            "\(key) is invalid: \(value)"
        case .invalidPort(let value):
            "AWAY_SSH_PORT must be an integer from 1 to 65535: \(value)"
        case .invalidP256PrivateKey(let key):
            "\(key) is not a valid P-256 private key."
        }
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
        "GOOSE_SERVE_URL",
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
        return merged
    }

    func saveExplicitSettings(from environment: [String: String]) {
        var hasAnyExplicitSetting = false
        for key in Self.keys {
            guard let value = environment[key] else { continue }
            hasAnyExplicitSetting = true
            defaults.set(value, forKey: storageKey(key))
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

    private func storageKey(_ key: String) -> String {
        Self.prefix + key
    }
}
