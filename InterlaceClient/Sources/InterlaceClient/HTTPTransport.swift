import Foundation

public struct InterlaceEndpoint: Equatable, Sendable {
    public let url: URL
    /// The household id this device belongs to, sent as `X-Person`.
    public let person: String

    public init(url: URL, person: String) {
        self.url = url
        self.person = person
    }
}

public final class HTTPTransport: FileUploadTransport, Sendable {
    private let resolve: @Sendable () -> InterlaceEndpoint?
    private let session: URLSession

    public init(
        configuration: URLSessionConfiguration = HTTPTransport.defaultConfiguration,
        endpoint resolve: @escaping @Sendable () -> InterlaceEndpoint?
    ) {
        self.resolve = resolve
        self.session = URLSession(configuration: configuration)
    }

    public static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.waitsForConnectivity = false
        return configuration
    }

    public func perform(_ request: InterlaceRequest) async throws -> InterlaceResponse {
        let (body, response) = try await session.data(for: urlRequest(request))
        return try Self.response(response, body: body)
    }

    public func upload(
        _ request: InterlaceRequest,
        fromFile fileURL: URL,
        prefix: Data,
        suffix: Data
    ) async throws -> InterlaceResponse {
        guard request.body == nil else { throw InterlaceError.invalidRequest }
        let built = try urlRequest(request)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preparation = Task.detached {
            try MultipartBody.write(fileURL: fileURL, prefix: prefix, suffix: suffix, to: temporary)
        }
        try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        let (body, response) = try await session.upload(for: built, fromFile: temporary)
        return try Self.response(response, body: body)
    }

    func urlRequest(_ request: InterlaceRequest) throws -> URLRequest {
        guard let endpoint = resolve(), !endpoint.person.isEmpty else { throw InterlaceError.notConfigured }
        guard var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              request.path.hasPrefix("/api/"),
              !request.path.contains("?"), !request.path.contains("#") else {
            throw InterlaceError.invalidRequest
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Setting percentEncodedPath requires a valid escape sequence at every percent sign.
        guard let path = URLComponents(string: request.path), path.percentEncodedPath == request.path else {
            throw InterlaceError.invalidRequest
        }
        components.percentEncodedPath = (basePath.isEmpty ? "" : "/" + basePath) + request.path
        components.queryItems = request.queryItems.isEmpty ? nil : request.queryItems.map {
            URLQueryItem(name: $0.name, value: $0.value)
        }
        // FastAPI treats a literal plus in a query as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url else { throw InterlaceError.invalidRequest }
        var built = URLRequest(url: url)
        built.httpMethod = request.method.rawValue
        built.setValue(endpoint.person, forHTTPHeaderField: "X-Person")
        built.setValue("application/json, image/jpeg", forHTTPHeaderField: "Accept")
        built.setValue(request.contentType, forHTTPHeaderField: "Content-Type")
        built.httpBody = request.body
        return built
    }

    private static func response(_ response: URLResponse, body: Data) throws -> InterlaceResponse {
        guard let http = response as? HTTPURLResponse else { throw InterlaceError.badResponse }
        return InterlaceResponse(status: http.statusCode, body: body)
    }
}
