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

    static let demo = demo(environment: ProcessInfo.processInfo.environment)

    static func demo(environment: [String: String]) -> RemoteConnectionConfig {
        let defaultCWD = environment["GOOSE_REMOTE_DEFAULT_CWD"] ?? "~"
        let keepaliveEnabled = environment["GOOSE_REMOTE_BACKGROUND_KEEPALIVE"] == "1"
        let mode = environment["GOOSE_REMOTE_TRANSPORT"].map(normalizeMode) ?? "sshstdio"

        switch mode {
        case "sshstdio":
            return RemoteConnectionConfig(
                mode: .sshStdio(makeSSHConfig(environment: environment)),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        case "sshforwardedwebsocket":
            let rawURL = environment["GOOSE_REMOTE_REMOTE_ACP_URL"] ?? defaultDirectWebSocketURL
            guard let remoteACPURL = URL(string: rawURL) else {
                preconditionFailure("GOOSE_REMOTE_REMOTE_ACP_URL is invalid: \(rawURL)")
            }
            return RemoteConnectionConfig(
                mode: .sshForwardedWebSocket(makeSSHConfig(environment: environment), remoteACPURL: remoteACPURL),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        case "directwebsocket", "websocket":
            let rawURL = environment["GOOSE_REMOTE_ACP_URL"] ?? defaultDirectWebSocketURL
            guard let url = URL(string: rawURL) else {
                preconditionFailure("GOOSE_REMOTE_ACP_URL is invalid: \(rawURL)")
            }
            return RemoteConnectionConfig(
                mode: .directWebSocket(url),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        default:
            preconditionFailure("Unsupported GOOSE_REMOTE_TRANSPORT: \(environment["GOOSE_REMOTE_TRANSPORT"] ?? mode)")
        }
    }

    private static let defaultDirectWebSocketURL = "ws://127.0.0.1:32845/acp?token=local-secret"

    private static func normalizeMode(_ raw: String) -> String {
        raw.filter(\.isLetter).lowercased()
    }

    private static func makeSSHConfig(environment: [String: String]) -> SSHConfig {
        let host = environment["GOOSE_REMOTE_SSH_HOST"] ?? "127.0.0.1"
        let port = environment["GOOSE_REMOTE_SSH_PORT"].flatMap(Int.init) ?? 22
        let username = environment["GOOSE_REMOTE_SSH_USERNAME"] ?? NSUserName()
        let command = environment["GOOSE_REMOTE_SSH_COMMAND"] ?? "goose acp"

        return SSHConfig(
            host: host,
            port: port,
            username: username,
            authentication: makeSSHAuthentication(environment: environment),
            command: command
        )
    }

    private static func makeSSHAuthentication(environment: [String: String]) -> SSHAuthentication {
        if let password = environment["GOOSE_REMOTE_SSH_PASSWORD"] {
            return .password(password)
        }

        if let pemBase64 = environment["GOOSE_REMOTE_SSH_P256_PRIVATE_KEY_PEM_BASE64"] {
            guard let data = Data(base64Encoded: pemBase64),
                  let pem = String(data: data, encoding: .utf8),
                  let key = try? P256.Signing.PrivateKey(pemRepresentation: pem)
            else {
                preconditionFailure("GOOSE_REMOTE_SSH_P256_PRIVATE_KEY_PEM_BASE64 is not a valid P-256 PEM key")
            }
            return .privateKey(NIOSSHPrivateKey(p256Key: key))
        }

        if let rawBase64 = environment["GOOSE_REMOTE_SSH_P256_PRIVATE_KEY_RAW_BASE64"] {
            guard let data = Data(base64Encoded: rawBase64),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: data)
            else {
                preconditionFailure("GOOSE_REMOTE_SSH_P256_PRIVATE_KEY_RAW_BASE64 is not a valid P-256 raw key")
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
