import Foundation

enum ACPError: LocalizedError, Equatable {
    case invalidURL(String)
    case connectionClosed
    case invalidResponse(String)
    case rpcError(String, data: JSONValue? = nil)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            "Invalid ACP URL: \(value)"
        case .connectionClosed:
            "ACP connection is closed."
        case .invalidResponse(let method):
            "Invalid ACP response for \(method)."
        case .rpcError(let message, let data):
            if let dataDescription = data?.stringValue {
                "\(message): \(dataDescription)"
            } else {
                message
            }
        case .timeout(let method):
            "Timed out waiting for \(method)."
        }
    }

    var isInvalidParams: Bool {
        guard case .rpcError(let message, _) = self else { return false }
        return message == "Invalid params"
    }

    var activeRunIDHint: String? {
        guard case .rpcError(_, let data) = self else { return nil }
        if let actualRunID = data?["actualRunId"]?.stringValue {
            return actualRunID
        }
        guard let message = data?.stringValue else { return nil }
        let prefix = "session already has active run `"
        guard let prefixRange = message.range(of: prefix) else { return nil }
        let remainder = message[prefixRange.upperBound...]
        guard let end = remainder.firstIndex(of: "`") else { return nil }
        return String(remainder[..<end])
    }

    var isNoActiveRunToSteer: Bool {
        guard case .rpcError(_, let data) = self else { return false }
        return data?.stringValue == "no active run to steer"
    }
}
