import Foundation
@preconcurrency import Crypto
import NIOSSH
import Security

struct RemoteConnectionConfig: Sendable {
    enum Mode: Sendable {
        case sshStdio(SSHConfig)
    }

    var mode: Mode
    var defaultCWD: String
    var demoBackgroundKeepaliveEnabled: Bool

    static let demo = demoResult(
        environment: ProcessInfo.processInfo.environment,
        settingsStore: .standard
    )

    static func demo(environment: [String: String]) throws -> RemoteConnectionConfig {
        try makeDemoConfig(environment: environment)
    }

    static func demo(
        environment: [String: String],
        settingsStore: DemoConnectionSettingsStore
    ) throws -> RemoteConnectionConfig {
        let environmentWebSocketKeys = settingsStore.unsupportedWebSocketSettingKeys(in: environment)
        if !environmentWebSocketKeys.isEmpty {
            let keys = environmentWebSocketKeys + settingsStore.unsupportedSavedWebSocketSettingKeys()
            throw RemoteConnectionConfigError.unsupportedWebSocketSettings(keys: keys)
        }

        let savedWebSocketKeys = settingsStore.unsupportedSavedWebSocketSettingKeys()
        if !savedWebSocketKeys.isEmpty, !settingsStore.environmentContainsConnectionSettings(environment) {
            throw RemoteConnectionConfigError.unsupportedWebSocketSettings(keys: savedWebSocketKeys)
        }

        let mergedEnvironment = try settingsStore.environmentByMergingSavedSettings(with: environment)
        let config = try makeDemoConfig(environment: mergedEnvironment)
        try settingsStore.saveExplicitSettings(from: environment)
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
            preconditionFailure("Unexpected demo connection configuration error: \(error.localizedDescription)")
        }
    }

    private static func makeDemoConfig(environment: [String: String]) throws -> RemoteConnectionConfig {
        let defaultCWD = try nonEmptyString(
            environment["AWAY_DEFAULT_CWD"],
            variable: "AWAY_DEFAULT_CWD",
            defaultValue: "~"
        )
        let keepaliveEnabled = environment["AWAY_BACKGROUND_KEEPALIVE"] == "1"
        let mode = environment["AWAY_TRANSPORT"].map(normalizeMode) ?? "sshstdio"

        switch mode {
        case "sshstdio":
            return RemoteConnectionConfig(
                mode: .sshStdio(try makeSSHConfig(environment: environment)),
                defaultCWD: defaultCWD,
                demoBackgroundKeepaliveEnabled: keepaliveEnabled
            )

        default:
            throw RemoteConnectionConfigError.unsupportedTransport(
                value: environment["AWAY_TRANSPORT"] ?? mode
            )
        }
    }

    private static func normalizeMode(_ raw: String) -> String {
        raw.filter(\.isLetter).lowercased()
    }

    private static func makeSSHConfig(environment: [String: String]) throws -> SSHConfig {
        let host = try nonEmptyString(
            environment["AWAY_SSH_HOST"],
            variable: "AWAY_SSH_HOST",
            defaultValue: "127.0.0.1"
        )
        let port = try sshPort(from: environment["AWAY_SSH_PORT"])
        let username = try nonEmptyString(
            environment["AWAY_SSH_USERNAME"],
            variable: "AWAY_SSH_USERNAME",
            defaultValue: NSUserName()
        )
        let command = try nonEmptyString(
            environment["AWAY_SSH_COMMAND"],
            variable: "AWAY_SSH_COMMAND",
            defaultValue: "goose acp"
        )

        return SSHConfig(
            host: host,
            port: port,
            username: username,
            authentication: try makeSSHAuthentication(environment: environment),
            command: command
        )
    }

    private static func makeSSHAuthentication(environment: [String: String]) throws -> SSHAuthentication {
        if let password = environment["AWAY_SSH_PASSWORD"] {
            return .password(password)
        }

        if let pemBase64 = environment["AWAY_SSH_P256_PRIVATE_KEY_PEM_BASE64"] {
            guard let data = Data(base64Encoded: pemBase64),
                  let pem = String(data: data, encoding: .utf8),
                  let key = try? P256.Signing.PrivateKey(pemRepresentation: pem)
            else {
                throw RemoteConnectionConfigError.invalidP256PrivateKey(
                    variable: "AWAY_SSH_P256_PRIVATE_KEY_PEM_BASE64"
                )
            }
            return .privateKey(NIOSSHPrivateKey(p256Key: key))
        }

        if let rawBase64 = environment["AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64"] {
            guard let data = Data(base64Encoded: rawBase64),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: data)
            else {
                throw RemoteConnectionConfigError.invalidP256PrivateKey(
                    variable: "AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64"
                )
            }
            return .privateKey(NIOSSHPrivateKey(p256Key: key))
        }

        return .none
    }

    private static func sshPort(from rawPort: String?) throws -> Int {
        guard let rawPort else { return 22 }
        let trimmed = rawPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65_535).contains(port) else {
            throw RemoteConnectionConfigError.invalidPort(
                value: rawPort,
                variable: "AWAY_SSH_PORT"
            )
        }
        return port
    }

    private static func nonEmptyString(
        _ value: String?,
        variable: String,
        defaultValue: String
    ) throws -> String {
        guard let value else { return defaultValue }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteConnectionConfigError.emptyValue(variable: variable)
        }
        return trimmed
    }
}

enum RemoteConnectionConfigError: LocalizedError, Equatable, Sendable {
    case unsupportedTransport(value: String)
    case invalidPort(value: String, variable: String)
    case emptyValue(variable: String)
    case invalidP256PrivateKey(variable: String)
    case unsupportedWebSocketSettings(keys: [String])
    case keychainAccessFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedTransport(let value):
            return "Unsupported AWAY_TRANSPORT '\(value)'. SSH stdio is the only supported transport; relaunch with AWAY_TRANSPORT=ssh-stdio."
        case .invalidPort(let value, let variable):
            return "\(variable) must be a TCP port from 1 through 65535, not '\(value)'."
        case .emptyValue(let variable):
            return "\(variable) must not be empty for SSH stdio demo configuration."
        case .invalidP256PrivateKey(let variable):
            return "\(variable) is not a valid base64-encoded P-256 private key."
        case .unsupportedWebSocketSettings(let keys):
            let joinedKeys = Array(Set(keys)).sorted().joined(separator: ", ")
            return "Found unsupported WebSocket demo settings (\(joinedKeys)). WebSocket transports were removed; relaunch with AWAY_* SSH stdio settings or reset the simulator app data."
        case .keychainAccessFailed(let operation, let status):
            return "Failed to \(operation) persisted SSH demo secret in Keychain (OSStatus \(status)). Relaunch with explicit AWAY_* SSH stdio settings after resetting simulator data."
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
    private static let supportedKeys = [
        "AWAY_TRANSPORT",
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
    private static let secretKeys = [
        "AWAY_SSH_PASSWORD",
        "AWAY_SSH_P256_PRIVATE_KEY_PEM_BASE64",
        "AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64"
    ]
    private static let unsupportedWebSocketKeys = [
        "AWAY_ACP_URL",
        "AWAY_REMOTE_ACP_URL"
    ]

    private let defaults: UserDefaults
    private let keychainService: String

    init(
        defaults: UserDefaults,
        keychainService: String = "xyz.block.away.demoConnection"
    ) {
        self.defaults = defaults
        self.keychainService = keychainService
    }

    func environmentByMergingSavedSettings(with environment: [String: String]) throws -> [String: String] {
        var merged = try savedSettings()
        for (key, value) in environment where Self.supportedKeys.contains(key) {
            merged[key] = value
        }
        if environmentContainsAuthSecretSettings(environment) {
            for key in Self.secretKeys where environment[key] == nil {
                merged.removeValue(forKey: key)
            }
        }
        if environmentContainsSSHSettings(environment), environment["AWAY_TRANSPORT"] == nil {
            merged["AWAY_TRANSPORT"] = "ssh-stdio"
        }
        return merged
    }

    func saveExplicitSettings(from environment: [String: String]) throws {
        var hasAnyExplicitSetting = false
        for key in Self.supportedKeys {
            guard let value = environment[key] else { continue }
            hasAnyExplicitSetting = true
            if Self.secretKeys.contains(key) {
                try saveKeychainSecret(value, for: key)
            } else {
                defaults.set(value, forKey: storageKey(key))
            }
        }

        if environmentContainsAuthSecretSettings(environment) {
            for key in Self.secretKeys where environment[key] == nil {
                try deleteKeychainSecret(for: key)
            }
        }

        if environmentContainsSSHSettings(environment), environment["AWAY_TRANSPORT"] == nil {
            hasAnyExplicitSetting = true
            defaults.set("ssh-stdio", forKey: storageKey("AWAY_TRANSPORT"))
        }

        if hasAnyExplicitSetting {
            clearUnsupportedWebSocketSettings()
            defaults.synchronize()
        }
    }

    func clear() {
        for key in Self.supportedKeys {
            defaults.removeObject(forKey: storageKey(key))
        }
        for key in Self.secretKeys {
            deleteKeychainSecretOrPreconditionFailure(for: key)
        }
        clearUnsupportedWebSocketSettings()
    }

    func environmentContainsConnectionSettings(_ environment: [String: String]) -> Bool {
        environment.keys.contains { key in
            key == "AWAY_TRANSPORT" || key.hasPrefix("AWAY_SSH_")
        }
    }

    func unsupportedWebSocketSettingKeys(in environment: [String: String]) -> [String] {
        Self.unsupportedWebSocketKeys.filter { environment[$0] != nil }
    }

    func unsupportedSavedWebSocketSettingKeys() -> [String] {
        Self.unsupportedWebSocketKeys.filter { defaults.object(forKey: storageKey($0)) != nil }
    }

    private func savedSettings() throws -> [String: String] {
        var settings: [String: String] = [:]
        for key in Self.supportedKeys {
            if Self.secretKeys.contains(key), let value = try keychainSecret(for: key) {
                settings[key] = value
            } else if !Self.secretKeys.contains(key), let value = defaults.string(forKey: storageKey(key)) {
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

    private func environmentContainsAuthSecretSettings(_ environment: [String: String]) -> Bool {
        environment.keys.contains { key in
            Self.secretKeys.contains(key)
        }
    }

    private func clearUnsupportedWebSocketSettings() {
        for key in Self.unsupportedWebSocketKeys {
            defaults.removeObject(forKey: storageKey(key))
        }
    }

    private func storageKey(_ key: String) -> String {
        Self.prefix + key
    }

    private func keychainSecret(for key: String) throws -> String? {
        var query = keychainQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw RemoteConnectionConfigError.keychainAccessFailed(
                operation: "read",
                status: status
            )
        }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw RemoteConnectionConfigError.keychainAccessFailed(
                operation: "read",
                status: errSecDecode
            )
        }
        return secret
    }

    private func saveKeychainSecret(_ value: String, for key: String) throws {
        try deleteKeychainSecret(for: key)

        guard let data = value.data(using: .utf8) else {
            throw RemoteConnectionConfigError.invalidP256PrivateKey(variable: key)
        }
        var item = keychainQuery(for: key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RemoteConnectionConfigError.keychainAccessFailed(
                operation: "save",
                status: status
            )
        }
    }

    private func deleteKeychainSecret(for key: String) throws {
        let status = SecItemDelete(keychainQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteConnectionConfigError.keychainAccessFailed(
                operation: "delete",
                status: status
            )
        }
    }

    private func deleteKeychainSecretOrPreconditionFailure(for key: String) {
        let status = SecItemDelete(keychainQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            preconditionFailure(
                "Failed to delete persisted SSH demo secret \(key) from Keychain: OSStatus \(status)"
            )
        }
    }

    private func keychainQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
    }
}
