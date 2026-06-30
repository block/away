import Foundation
import NIOCore
import NIOSSH

actor SSHStdioTransport: ACPTransport {
    nonisolated let messages: AsyncStream<String>

    private let config: SSHConfig
    private let continuation: AsyncStream<String>.Continuation
    private var connection: SSHClientConnection?
    private var childChannel: Channel?

    init(config: SSHConfig) {
        self.config = config
        var capturedContinuation: AsyncStream<String>.Continuation?
        self.messages = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    func connect() async throws {
        guard childChannel == nil else { return }
        guard let command = config.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else {
            throw SSHTransportError.missingCommand
        }

        let connection = SSHClientConnection(config: config)
        let sshChannel = try await connection.connect()
        let continuation = self.continuation
        let childChannel = try await sshChannel.pipeline.handler(type: NIOSSHHandler.self)
            .flatMap { sshHandler in
                let promise = sshChannel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(SSHTransportError.invalidChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandler(
                            SSHLineChannelHandler(command: command) { [continuation] line in
                                continuation.yield(line)
                            }
                        )
                        try childChannel.pipeline.syncOperations.addHandler(SSHErrorHandler())
                    }
                }
                return promise.futureResult
            }
            .asyncValue()

        self.connection = connection
        self.childChannel = childChannel
    }

    func send(_ message: String) async throws {
        guard let childChannel else {
            throw ACPError.connectionClosed
        }
        var buffer = childChannel.allocator.buffer(capacity: message.utf8.count + 1)
        buffer.writeString(message)
        buffer.writeString("\n")
        try await childChannel.writeAndFlush(buffer).asyncValue()
    }

    func close() async {
        if let childChannel {
            try? await childChannel.close().asyncValue()
        }
        childChannel = nil
        await connection?.close()
        connection = nil
        continuation.finish()
    }
}
