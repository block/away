import Foundation

enum ACPError: LocalizedError, Equatable {
    case invalidURL(String)
    case connectionClosed
    case invalidResponse(String)
    case rpcError(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            "Invalid ACP URL: \(value)"
        case .connectionClosed:
            "ACP connection is closed."
        case .invalidResponse(let method):
            "Invalid ACP response for \(method)."
        case .rpcError(let message):
            message
        case .timeout(let method):
            "Timed out waiting for \(method)."
        }
    }

    var isInvalidParams: Bool {
        guard case .rpcError(let message) = self else { return false }
        return message == "Invalid params"
    }
}
