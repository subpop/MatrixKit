/// HTTP methods supported by the transport.
public enum HTTPMethod: String, Hashable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}
