import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import GooseRemote

final class SSHStdioTransportIntegrationTests: XCTestCase {
    func testStdioTransportRoundTripsJSONLineThroughSSHExecChannel() async throws {
        let server = LoopbackSSHACPServer()
        let port = try await server.start()

        let transport = SSHStdioTransport(
            config: SSHConfig(
                host: "127.0.0.1",
                port: port,
                username: "goose",
                authentication: .password("secret"),
                command: "goose acp"
            )
        )

        let received = Task<String?, Never> {
            for await message in transport.messages {
                return message
            }
            return nil
        }

        do {
            try await transport.connect()
            try await transport.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)

            let response = await received.value
            XCTAssertEqual(response, #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#)
            await transport.close()
            await server.stop()
        } catch {
            received.cancel()
            await transport.close()
            await server.stop()
            throw error
        }
    }
}

private final class LoopbackSSHACPServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var serverChannel: Channel?

    func start() async throws -> Int {
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .server(
                            .init(
                                hostKeys: [hostKey],
                                userAuthDelegate: LoopbackPasswordDelegate()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: Self.childChannelInitializer(_:_:)
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(LoopbackErrorHandler())
                }
            }
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).asyncValue()
        serverChannel = channel
        return try XCTUnwrap(channel.localAddress?.port)
    }

    func stop() async {
        if let serverChannel {
            try? await serverChannel.close().asyncValue()
        }
        serverChannel = nil
        try? await group.shutdownGracefullyAsync()
    }

    private static func childChannelInitializer(_ channel: Channel, _ channelType: SSHChannelType) -> EventLoopFuture<Void> {
        guard channelType == .session else {
            return channel.eventLoop.makeFailedFuture(SSHTransportError.invalidChannelType)
        }
        return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(LoopbackACPExecHandler())
        }
    }
}

private final class LoopbackPasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        .password
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == "goose",
              case .password(let passwordRequest) = request.request,
              passwordRequest.password == "secret"
        else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

private final class LoopbackACPExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private var command: String?
    private var pendingInput = ""

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? SSHChannelRequestEvent.ExecRequest {
            command = event.command
            if event.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type,
              case .byteBuffer(var buffer) = data.data,
              let text = buffer.readString(length: buffer.readableBytes)
        else {
            context.fireErrorCaught(SSHTransportError.invalidData)
            return
        }

        pendingInput += text
        while let newlineIndex = pendingInput.firstIndex(of: "\n") {
            let line = String(pendingInput[..<newlineIndex])
            pendingInput.removeSubrange(...newlineIndex)
            guard line.contains(#""method":"ping""#), command == "goose acp" else {
                continue
            }
            writeLine(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#, context: context)
        }
    }

    private func writeLine(_ line: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: line.utf8.count + 1)
        buffer.writeString(line)
        buffer.writeString("\n")
        context.writeAndFlush(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: nil
        )
    }
}

private final class LoopbackErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
