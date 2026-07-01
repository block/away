import Foundation

struct AppEnvironment: Sendable {
    var connectionConfig: RemoteConnectionConfig

    static let demo = AppEnvironment(connectionConfig: .demo)
}
