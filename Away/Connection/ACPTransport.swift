import Foundation

protocol ACPTransport: Sendable {
    var messages: AsyncStream<String> { get }
    func connect() async throws
    func send(_ message: String) async throws
    func close() async
}
