import Foundation

struct RemoteConnectionProvider: Sendable {
    func makeTransport(config: RemoteConnectionConfig) throws -> any ACPTransport {
        switch config.mode {
        case .sshStdio(let ssh):
            return SSHStdioTransport(config: ssh)
        }
    }
}
