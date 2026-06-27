import Foundation

struct ACPRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: JSONValue
}

struct ACPResponse: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let result: JSONValue
}
