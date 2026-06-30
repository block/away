import Foundation
@preconcurrency import NIOCore
import NIOPosix
import NIOSSH

enum SSHTransportError: LocalizedError {
    case missingCommand
    case connectionFailed(host: String, port: Int, underlying: String)
    case invalidChannelType
    case invalidData
    case authenticationUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "SSH stdio transport requires a Goose ACP stdio command."
        case .connectionFailed(let host, let port, let underlying):
            return "SSH stdio failed to connect to \(host):\(port). Check AWAY_SSH_HOST, AWAY_SSH_PORT, and that the local sshd is running. Underlying error: \(underlying)"
        case .invalidChannelType:
            return "SSH opened an unexpected channel type."
        case .invalidData:
            return "SSH channel received unsupported data."
        case .authenticationUnavailable:
            return "The SSH server did not offer a configured authentication method."
        }
    }
}

final class AcceptAllSSHHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

final class StaticSSHAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var authentication: SSHAuthentication?

    init(username: String, authentication: SSHAuthentication) {
        self.username = username
        self.authentication = authentication
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard let authentication else {
            nextChallengePromise.succeed(nil)
            return
        }

        switch authentication {
        case .none:
            self.authentication = nil
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .none
                )
            )

        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.fail(SSHTransportError.authenticationUnavailable)
                return
            }
            self.authentication = nil
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .password(.init(password: password))
                )
            )

        case .privateKey(let key):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.fail(SSHTransportError.authenticationUnavailable)
                return
            }
            self.authentication = nil
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .privateKey(.init(privateKey: key))
                )
            )
        }
    }
}

final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

final class SSHClientConnection: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let config: SSHConfig
    private var channel: Channel?

    init(config: SSHConfig) {
        self.config = config
    }

    func connect() async throws -> Channel {
        if let channel, channel.isActive {
            return channel
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [config] channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: StaticSSHAuthenticationDelegate(
                                    username: config.username,
                                    authentication: config.authentication
                                ),
                                serverAuthDelegate: AcceptAllSSHHostKeysDelegate()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(SSHErrorHandler())
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: config.host, port: config.port).asyncValue()
        } catch {
            throw SSHTransportError.connectionFailed(
                host: config.host,
                port: config.port,
                underlying: error.localizedDescription
            )
        }
        self.channel = channel
        return channel
    }

    func close() async {
        if let channel {
            try? await channel.close().asyncValue()
        }
        channel = nil
        try? await group.shutdownGracefullyAsync()
    }
}

final class SSHLineChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let onLine: @Sendable (String) -> Void
    private var pendingText = ""

    init(command: String, onLine: @escaping @Sendable (String) -> Void) {
        self.command = command
        self.onLine = onLine
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            loopBoundContext.value.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(execRequest).whenFailure { _ in
            loopBoundContext.value.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = data.data else {
            context.fireErrorCaught(SSHTransportError.invalidData)
            return
        }

        switch data.type {
        case .channel:
            guard let text = buffer.readString(length: buffer.readableBytes) else { return }
            pendingText += text
            drainCompleteLines()
        case .stdErr:
            return
        default:
            context.fireErrorCaught(SSHTransportError.invalidData)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let trailing = pendingText.trimmingCharacters(in: .newlines)
        if !trailing.isEmpty {
            onLine(trailing)
        }
        pendingText = ""
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }

    private func drainCompleteLines() {
        while let newlineIndex = pendingText.firstIndex(of: "\n") {
            let line = String(pendingText[..<newlineIndex]).trimmingCharacters(in: .newlines)
            pendingText.removeSubrange(...newlineIndex)
            if !line.isEmpty {
                onLine(line)
            }
        }
    }
}

extension EventLoopFuture {
    func asyncValue() async throws -> Value {
        let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NIOFutureValueBox<Value>, Error>) in
            whenComplete { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: NIOFutureValueBox(value: value))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
        return box.value
    }
}

private struct NIOFutureValueBox<Value>: @unchecked Sendable {
    var value: Value
}

extension EventLoopGroup {
    func shutdownGracefullyAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
