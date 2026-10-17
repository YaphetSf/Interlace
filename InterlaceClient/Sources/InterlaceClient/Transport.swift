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
    /// Stream `prefix`, the file's bytes, and `suffix` as the request body.
    func upload(
        _ request: InterlaceRequest,
        fromFile fileURL: URL,
        prefix: Data,
        suffix: Data
    ) async throws -> InterlaceResponse
}

public enum InterlaceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case unauthorized
    case http(status: Int, detail: String)
    case badResponse
    case invalidRequest
    case fileUploadUnsupported

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No Interlace server configured"
        case .unauthorized: "Interlace key not accepted"
        case .http(let status, let detail): detail.isEmpty ? "Interlace returned HTTP \(status)" : detail
        case .badResponse: "Unexpected reply from Interlace"
        case .invalidRequest: "Invalid Interlace request"
        case .fileUploadUnsupported: "This connection does not support file uploads"
        }
    }
}
