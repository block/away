import Foundation

actor ACPClient {
    nonisolated let notifications: AsyncStream<ACPNotification>

    private let transport: any ACPTransport
    private let notificationContinuation: AsyncStream<ACPNotification>.Continuation
    private var nextID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var receiveTask: Task<Void, Never>?

    init(transport: any ACPTransport) {
        self.transport = transport
        var capturedContinuation: AsyncStream<ACPNotification>.Continuation?
        self.notifications = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.notificationContinuation = capturedContinuation!
    }

    func connect() async throws {
        try await transport.connect()
        receiveTask = Task { [transport] in
            for await message in transport.messages {
                self.handle(rawMessage: message)
            }
        }
        try await initialize()
    }

    func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        let pendingRequests = pending
        pending.removeAll()
        for pending in pendingRequests.values {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: ACPError.connectionClosed)
        }
        await transport.close()
        notificationContinuation.finish()
    }

    func listSessions() async throws -> [SessionSummary] {
        let result = try await request(
            method: "session/list",
            params: [
                "_meta": [
                    "goose": [
                        "includeLastMessageSnippet": true
                    ]
                ],
                "cursor": .null,
                "cwd": .null
            ],
            timeout: 30
        )

        guard let sessions = result["sessions"]?.arrayValue else {
            throw ACPError.invalidResponse("session/list")
        }

        return sessions.compactMap(SessionSummary.init(json:))
    }

    func loadSession(sessionID: String, cwd: String) async throws {
        _ = try await request(
            method: "session/load",
            params: [
                "sessionId": .string(sessionID),
                "cwd": .string(cwd),
                "mcpServers": []
            ],
            timeout: 60
        )
    }

    func exportSession(sessionID: String) async throws -> String {
        let result = try await request(
            method: "_goose/unstable/session/export",
            params: [
                "sessionId": .string(sessionID)
            ],
            timeout: 30
        )

        guard let data = result["data"]?.stringValue else {
            throw ACPError.invalidResponse("_goose/unstable/session/export")
        }

        return data
    }

    func sendPrompt(sessionID: String, messageID: String, text: String) async throws {
        _ = try await request(
            method: "session/prompt",
            params: promptParams(sessionID: sessionID, messageID: messageID, text: text),
            timeout: 300
        )
    }

    func steer(sessionID: String, expectedRunID: String, text: String) async throws -> String {
        let result = try await request(
            method: "_goose/unstable/session/steer",
            params: [
                "sessionId": .string(sessionID),
                "expectedRunId": .string(expectedRunID),
                "prompt": [
                    [
                        "type": "text",
                        "text": .string(text.isEmpty ? " " : text)
                    ]
                ]
            ],
            timeout: 60
        )

        return result["runId"]?.stringValue ?? expectedRunID
    }

    func cancel(sessionID: String) async throws {
        _ = try await request(
            method: "session/cancel",
            params: ["sessionId": .string(sessionID)],
            timeout: 30
        )
    }

    private func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "goose": [
                        "unstable": true
                    ],
                    "_meta": [
                        "goose": [
                            "unstable": true
                        ]
                    ]
                ],
                "clientInfo": [
                    "name": "goose-ios-remote",
                    "title": "Goose iOS Remote",
                    "version": "1.0.0"
                ]
            ],
            timeout: 30
        )
    }

    private func request(method: String, params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let request = ACPRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ACPError.invalidResponse(method)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.timeoutRequest(id: id, method: method)
                }
                pending[id] = PendingRequest(method: method, continuation: continuation, timeoutTask: timeoutTask)
                Task { [weak self, transport] in
                    do {
                        try await transport.send(text)
                    } catch {
                        await self?.failRequest(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func promptParams(sessionID: String, messageID: String, text: String) -> JSONValue {
        [
            "sessionId": .string(sessionID),
            "messageId": .string(messageID),
            "prompt": [
                ACPContentBlock.text(text).jsonValue()
            ]
        ]
    }

    private func handle(rawMessage: String) {
        guard let data = rawMessage.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ACPEnvelope.self, from: data)
        else {
            return
        }

        if let notification = ACPNotification.from(envelope: envelope) {
            notificationContinuation.yield(notification)
            return
        }

        if let method = envelope.method, let id = envelope.id {
            Task {
                await respondToServerRequest(id: id, method: method, params: envelope.params)
            }
            return
        }

        guard let id = envelope.id, let pending = pending.removeValue(forKey: id) else {
            return
        }

        pending.timeoutTask.cancel()
        if let error = envelope.error {
            pending.continuation.resume(throwing: ACPError.rpcError(error.message))
        } else {
            pending.continuation.resume(returning: envelope.result ?? .object([:]))
        }
    }

    private func respondToServerRequest(id: Int, method: String, params: JSONValue?) async {
        let result: JSONValue
        if method.localizedCaseInsensitiveContains("permission") {
            let options = params?["options"]?.arrayValue
            let optionID = options?.first?.objectValue?["optionId"]?.stringValue ?? "approve"
            result = [
                "outcome": [
                    "outcome": "selected",
                    "optionId": .string(optionID)
                ]
            ]
        } else {
            result = .object([:])
        }

        do {
            let response = ACPResponse(id: id, result: result)
            let data = try JSONEncoder().encode(response)
            if let text = String(data: data, encoding: .utf8) {
                try await transport.send(text)
            }
        } catch {
            // Server callbacks are best-effort for v0.
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.continuation.resume(throwing: ACPError.timeout(method))
    }

    private func failRequest(id: Int, error: Error) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func cancelRequest(id: Int) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: CancellationError())
    }
}

private struct PendingRequest {
    let method: String
    let continuation: CheckedContinuation<JSONValue, Error>
    let timeoutTask: Task<Void, Never>
}
