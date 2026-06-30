import Foundation

struct AppEnvironment: Sendable {
    var connectionConfig: Result<RemoteConnectionConfig, RemoteConnectionConfigError>

    static let demo = AppEnvironment(connectionConfig: RemoteConnectionConfig.demo)
}
