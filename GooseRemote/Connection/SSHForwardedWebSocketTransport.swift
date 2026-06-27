import Foundation

actor SSHForwardedWebSocketTransport: ACPTransport {
    nonisolated let messages: AsyncStream<String>

    private let config: SSHConfig
    private let remoteACPURL: URL
    private let continuation: AsyncStream<String>.Continuation
    private var forwarder: SSHLocalPortForwarder?
    private var webSocketTransport: DirectWebSocketTransport?
    private var bridgeTask: Task<Void, Never>?

    init(config: SSHConfig, remoteACPURL: URL) {
        self.config = config
        self.remoteACPURL = remoteACPURL
        var capturedContinuation: AsyncStream<String>.Continuation?
        self.messages = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    func connect() async throws {
        guard webSocketTransport == nil else { return }
        let endpoint = try SSHForwardedWebSocketEndpoint(remoteACPURL: remoteACPURL)

        let forwarder = SSHLocalPortForwarder(
            config: config,
            remoteHost: endpoint.remoteHost,
            remotePort: endpoint.remotePort
        )
        let localPort = try await forwarder.start()
        let localURL = try endpoint.localURL(localPort: localPort)
        let webSocketTransport = DirectWebSocketTransport(url: localURL)

        bridgeTask = Task { [webSocketTransport, continuation] in
            for await message in webSocketTransport.messages {
                continuation.yield(message)
            }
        }
        self.forwarder = forwarder
        self.webSocketTransport = webSocketTransport
        try await webSocketTransport.connect()
    }

    func send(_ message: String) async throws {
        guard let webSocketTransport else {
            throw ACPError.connectionClosed
        }
        try await webSocketTransport.send(message)
    }

    func close() async {
        bridgeTask?.cancel()
        bridgeTask = nil
        await webSocketTransport?.close()
        webSocketTransport = nil
        await forwarder?.close()
        forwarder = nil
        continuation.finish()
    }
}

struct SSHForwardedWebSocketEndpoint: Equatable, Sendable {
    var remoteACPURL: URL
    var remoteHost: String
    var remotePort: Int

    init(remoteACPURL: URL) throws {
        guard remoteACPURL.scheme == "ws" else {
            throw SSHTransportError.unsupportedForwardedScheme(remoteACPURL.scheme ?? "unknown")
        }
        guard let remoteHost = remoteACPURL.host else {
            throw SSHTransportError.missingRemoteHost(remoteACPURL)
        }
        guard let remotePort = remoteACPURL.port else {
            throw SSHTransportError.missingRemotePort(remoteACPURL)
        }

        self.remoteACPURL = remoteACPURL
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    func localURL(localPort: Int) throws -> URL {
        guard var components = URLComponents(url: remoteACPURL, resolvingAgainstBaseURL: false) else {
            throw SSHTransportError.missingRemoteHost(remoteACPURL)
        }
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = localPort
        guard let url = components.url else {
            throw SSHTransportError.missingRemoteHost(remoteACPURL)
        }
        return url
    }
}
