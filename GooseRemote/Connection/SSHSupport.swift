import Foundation
@preconcurrency import NIOCore
import NIOPosix
import NIOSSH

enum SSHTransportError: LocalizedError {
    case missingCommand
    case unsupportedForwardedScheme(String)
    case missingRemoteHost(URL)
    case missingRemotePort(URL)
    case invalidChannelType
    case invalidData
    case authenticationUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "SSH stdio transport requires a Goose ACP stdio command."
        case .unsupportedForwardedScheme(let scheme):
            return "SSH-forwarded WebSocket supports ws:// URLs for the local forwarded demo path, not \(scheme)://."
        case .missingRemoteHost(let url):
            return "SSH-forwarded WebSocket URL is missing a remote host: \(url.absoluteString)."
        case .missingRemotePort(let url):
            return "SSH-forwarded WebSocket URL is missing a remote port: \(url.absoluteString)."
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

        let channel = try await bootstrap.connect(host: config.host, port: config.port).asyncValue()
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

final class SSHByteBufferWrapperHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(SSHTransportError.invalidData)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}

final class NIOGlueHandler {
    private var partner: NIOGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (NIOGlueHandler, NIOGlueHandler) {
        let first = NIOGlueHandler()
        let second = NIOGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
}

extension NIOGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

final class SSHLocalPortForwarder: @unchecked Sendable {
    private let connection: SSHClientConnection
    private let remoteHost: String
    private let remotePort: Int
    private let bindHost: String
    private var serverChannel: Channel?

    init(config: SSHConfig, remoteHost: String, remotePort: Int, bindHost: String = "127.0.0.1") {
        self.connection = SSHClientConnection(config: config)
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.bindHost = bindHost
    }

    func start() async throws -> Int {
        let sshChannel = try await connection.connect()
        let server = try await ServerBootstrap(group: sshChannel.eventLoop, childGroup: sshChannel.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [remoteHost, remotePort] inboundChannel in
                sshChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                    let promise = inboundChannel.eventLoop.makePromise(of: Channel.self)
                    let originatorAddress: SocketAddress
                    do {
                        originatorAddress = try inboundChannel.remoteAddress
                            ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)
                    } catch {
                        return inboundChannel.eventLoop.makeFailedFuture(error)
                    }
                    let directTCPIP = SSHChannelType.DirectTCPIP(
                        targetHost: remoteHost,
                        targetPort: remotePort,
                        originatorAddress: originatorAddress
                    )
                    sshHandler.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { childChannel, channelType in
                        guard case .directTCPIP = channelType else {
                            return childChannel.eventLoop.makeFailedFuture(SSHTransportError.invalidChannelType)
                        }

                        return childChannel.eventLoop.makeCompletedFuture {
                            let (ours, theirs) = NIOGlueHandler.matchedPair()
                            try childChannel.pipeline.syncOperations.addHandler(SSHByteBufferWrapperHandler())
                            try childChannel.pipeline.syncOperations.addHandler(ours)
                            try childChannel.pipeline.syncOperations.addHandler(SSHErrorHandler())
                            try inboundChannel.pipeline.syncOperations.addHandler(theirs)
                            try inboundChannel.pipeline.syncOperations.addHandler(SSHErrorHandler())
                        }
                    }
                    return promise.futureResult.map { _ in }
                }
            }
            .bind(host: bindHost, port: 0)
            .asyncValue()

        serverChannel = server
        return server.localAddress?.port ?? 0
    }

    func close() async {
        if let serverChannel {
            try? await serverChannel.close().asyncValue()
        }
        serverChannel = nil
        await connection.close()
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
