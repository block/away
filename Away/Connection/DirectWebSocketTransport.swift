import Foundation

actor DirectWebSocketTransport: ACPTransport {
    nonisolated let messages: AsyncStream<String>

    private let url: URL
    private let continuation: AsyncStream<String>.Continuation
    private var task: URLSessionWebSocketTask?

    init(url: URL) {
        self.url = url
        var capturedContinuation: AsyncStream<String>.Continuation?
        self.messages = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    func connect() async throws {
        guard task == nil else { return }
        let webSocketTask = URLSession.shared.webSocketTask(with: url)
        task = webSocketTask
        webSocketTask.resume()
        receiveLoop(webSocketTask)
    }

    func send(_ message: String) async throws {
        guard let task else {
            throw ACPError.connectionClosed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.string(message)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation.finish()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task {
                await self.handle(result, task: task)
            }
        }
    }

    private func handle(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        task: URLSessionWebSocketTask
    ) {
        switch result {
        case .success(.string(let value)):
            continuation.yield(value)
            receiveLoop(task)
        case .success(.data(let data)):
            if let value = String(data: data, encoding: .utf8) {
                continuation.yield(value)
            }
            receiveLoop(task)
        case .success:
            receiveLoop(task)
        case .failure:
            continuation.finish()
        }
    }
}
