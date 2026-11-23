import Foundation
import Synchronization

public struct InterlaceEndpoint: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}

public final class HTTPTransport: FileUploadTransport, Sendable {
    private let resolve: @Sendable () -> InterlaceEndpoint?
    private let key: @Sendable () -> String?
    private let session: URLSession

    public init(
        configuration: URLSessionConfiguration = HTTPTransport.defaultConfiguration,
        key: @escaping @Sendable () -> String?,
        endpoint resolve: @escaping @Sendable () -> InterlaceEndpoint?
    ) {
        self.resolve = resolve
        self.key = key
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
        try await load(urlRequest(request), delegate: nil)
    }

    public func fileRequest(path: String) throws -> URLRequest {
        var request = try urlRequest(InterlaceRequest(
            path: "/api/file", queryItems: [.init(name: "path", value: path)]
        ))
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    public func upload(
        _ request: InterlaceRequest,
        fromFile fileURL: URL,
        prefix: Data,
        suffix: Data,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> InterlaceResponse {
        guard request.body == nil else { throw InterlaceError.invalidRequest }
        var built = try urlRequest(request)
        let body = try MultipartFileBody(fileURL: fileURL, prefix: prefix, suffix: suffix)
        defer { body.stop() }
        built.setValue(String(body.length), forHTTPHeaderField: "Content-Length")
        built.httpBodyStream = try body.stream()
        return try await load(built, delegate: UploadDelegate(body: body, progress: progress))
    }

    /// URLSession ends a cancelled Task's request with URLError.cancelled; callers get CancellationError.
    private func load(_ request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> InterlaceResponse {
        do {
            let (body, response) = try await session.data(for: request, delegate: delegate)
            return try Self.response(response, body: body)
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        }
    }

    func urlRequest(_ request: InterlaceRequest) throws -> URLRequest {
        guard let endpoint = resolve() else { throw InterlaceError.notConfigured }
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
        built.setValue(key().map { "Bearer \($0)" }, forHTTPHeaderField: "Authorization")
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

final class UploadDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let body: MultipartFileBody
    private let progress: (@Sendable (Double) -> Void)?
    private let reported = Mutex(0)

    init(body: MultipartFileBody, progress: (@Sendable (Double) -> Void)?) {
        self.body = body
        self.progress = progress
    }

    /// Reports each new tenth of a percent, so a large upload does not flood the caller.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard let progress, totalBytesExpectedToSend > 0 else { return }
        let permille = Int(min(totalBytesSent, totalBytesExpectedToSend) * 1000 / totalBytesExpectedToSend)
        let advanced = reported.withLock { last in
            guard permille > last else { return false }
            last = permille
            return true
        }
        if advanced { progress(Double(permille) / 1000) }
    }

    /// URLSession asks again when it must resend the body, as on a dropped keep-alive connection.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        completionHandler(try? body.stream())
    }
}
