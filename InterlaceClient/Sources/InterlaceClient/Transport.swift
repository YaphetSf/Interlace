import Foundation

public struct InterlaceRequest: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    public struct QueryItem: Codable, Equatable, Sendable {
        public let name: String
        public let value: String?

        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    public let method: Method
    /// Percent-encoded path beginning with `/api/`, relative to the endpoint's base path.
    public let path: String
    public let queryItems: [QueryItem]
    public let body: Data?
    public let contentType: String?

    public init(
        method: Method = .get,
        path: String,
        queryItems: [QueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.body = body
        self.contentType = contentType
    }
}

public struct InterlaceResponse: Codable, Equatable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol Transport: Sendable {
    /// Return HTTP errors unchanged so the client also handles errors delivered by a watch relay.
    func perform(_ request: InterlaceRequest) async throws -> InterlaceResponse
}

public protocol FileUploadTransport: Transport {
    /// Stream `prefix`, the file's bytes, and `suffix` as the request body, reporting the fraction sent.
    func upload(
        _ request: InterlaceRequest,
        fromFile fileURL: URL,
        prefix: Data,
        suffix: Data,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> InterlaceResponse
}

public enum InterlaceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case unauthorized
    /// `detail` is the server's own sentence, or empty when it sent none.
    case http(status: Int, detail: String)
    case badResponse
    case invalidRequest
    case fileUploadUnsupported

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No Interlace server configured"
        case .unauthorized: "Not accepted"
        case .http(let status, let detail) where detail.isEmpty:
            switch status {
            case 404: "Not found on Interlace"
            case 400..<500: "Interlace rejected the request"
            case 502, 503, 504: "Interlace is unavailable"
            default: "Interlace hit an error"
            }
        case .http(_, let detail): detail
        case .badResponse: "Unexpected reply from Interlace"
        case .invalidRequest: "Invalid Interlace request"
        case .fileUploadUnsupported: "This connection does not support file uploads"
        }
    }
}
