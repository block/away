import Foundation

struct AppEnvironment: Sendable {
    var connectionConfigResult: Result<RemoteConnectionConfig, RemoteConnectionConfigError>

    static let demo = AppEnvironment(connectionConfigResult: RemoteConnectionConfig.demoResult)
}
