import Foundation

struct RemoteConnectionProvider: Sendable {
    func makeTransport(config: RemoteConnectionConfig) throws -> any ACPTransport {
        switch config.mode {
        case .directWebSocket(let url):
            return DirectWebSocketTransport(url: url)
        case .sshStdio(let ssh):
            return SSHStdioTransport(config: ssh)
        case .sshForwardedWebSocket(let ssh, let remoteACPURL):
            return SSHForwardedWebSocketTransport(config: ssh, remoteACPURL: remoteACPURL)
        }
    }
}
