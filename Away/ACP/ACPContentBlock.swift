import Foundation

enum ACPContentBlock: Codable, Equatable, Sendable {
    case text(String, audience: [String]? = nil)
    case image(data: String, mimeType: String)

    func jsonValue() -> JSONValue {
        switch self {
        case .text(let text, let audience):
            var object: [String: JSONValue] = [
                "type": "text",
                "text": .string(text.isEmpty ? " " : text)
            ]
            if let audience {
                object["annotations"] = [
                    "audience": .array(audience.map(JSONValue.string))
                ]
            }
            return .object(object)
        case .image(let data, let mimeType):
            return [
                "type": "image",
                "data": .string(data),
                "mimeType": .string(mimeType)
            ]
        }
    }
}
