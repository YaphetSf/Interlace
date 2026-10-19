import Foundation
import Synchronization
import Testing
@testable import InterlaceClient

@Test func requestAndResponseRoundTripInWatchMessageDictionaries() throws {
    let request = InterlaceRequest(
        method: .post, path: "/api/upload/subtitle",
        queryItems: [.init(name: "path", value: "Season 1/Film & Cut.mkv"), .init(name: "flag", value: nil)],
        body: Data([0, 1, 13, 10, 255]), contentType: "multipart/form-data; boundary=watch"
    )
    let response = InterlaceResponse(status: 401, body: try fixture("error"))
    let message: [String: Data] = ["request": try JSONEncoder().encode(request), "response": try JSONEncoder().encode(response)]
    let encoded = try PropertyListSerialization.data(fromPropertyList: message, format: .binary, options: 0)
    let decoded = try #require(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Data])
    #expect(try JSONDecoder().decode(InterlaceRequest.self, from: #require(decoded["request"])) == request)
    #expect(try JSONDecoder().decode(InterlaceResponse.self, from: #require(decoded["response"])) == response)
    let empty = InterlaceRequest(path: "/api/health")
    #expect(try JSONDecoder().decode(InterlaceRequest.self, from: JSONEncoder().encode(empty)) == empty)
}

@Test func clientMapsErrorsFromAnyTransport() async throws {
    func client(status: Int, body: Data = Data()) -> InterlaceClient {
        InterlaceClient(transport: FixedTransport(response: .init(status: status, body: body)))
    }
    await #expect(throws: InterlaceError.unauthorized) { try await client(status: 401).health() }
    await #expect(throws: InterlaceError.http(status: 403, detail: "Access denied: Path outside download directory.")) {
        try await client(status: 403, body: fixture("error")).health()
    }
    await #expect(throws: InterlaceError.http(status: 502, detail: "")) {
        try await client(status: 502, body: Data("upstream down".utf8)).health()
    }
    await #expect(throws: InterlaceError.badResponse) { try await client(status: 200, body: Data("{}".utf8)).health() }
    await #expect(throws: InterlaceError.http(status: 404, detail: "")) {
        try await client(status: 404).thumbnail(path: "/downloads/missing.mkv")
    }
    let validation = client(status: 422, body: try fixture("validation-error"))
    do {
        _ = try await validation.health()
        Issue.record("Expected validation error")
    } catch let InterlaceError.http(status, detail) {
        #expect(status == 422)
        #expect(detail.contains("Field required") && detail.contains("path"))
    }
    let created = try await client(status: 201, body: fixture("ok")).health()
    #expect(created.ok)
    #expect(InterlaceError.unauthorized.localizedDescription == "Not accepted")
    #expect(InterlaceError.http(status: 502, detail: "kodi: offline").localizedDescription == "kodi: offline")
    #expect(InterlaceError.notConfigured.localizedDescription == "No Interlace server configured")
    #expect(InterlaceError.http(status: 502, detail: "").localizedDescription == "Interlace returned HTTP 502")
}

@Test func aRelayWithoutDiskUploadsReportsATypedError() async throws {
    let client = InterlaceClient(transport: FixedTransport(response: .init(status: 200, body: Data())))
    await #expect(throws: InterlaceError.fileUploadUnsupported) {
        try await client.upload(fileURL: URL(fileURLWithPath: "/film.mkv"))
    }
}

private struct Echo: Decodable {
    let url: String
    let method: String
    let incandenza: String?
    let authorization: String?
    let contentType: String?
    let body: Data?
}

private final class EchoProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try #require(request.url)
            let status = url.path == "/api/unauthorized" ? 401 : 200
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            var payload: [String: String] = ["url": url.absoluteString, "method": request.httpMethod ?? ""]
            payload["incandenza"] = request.value(forHTTPHeaderField: "X-Incandenza")
            payload["authorization"] = request.value(forHTTPHeaderField: "Authorization")
            payload["contentType"] = request.value(forHTTPHeaderField: "Content-Type")
            payload["body"] = request.httpBody?.base64EncodedString()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw stream.streamError ?? InterlaceError.badResponse }
                    if count == 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                payload["body"] = bytes.base64EncodedString()
            }
            let bytes = try JSONEncoder().encode(payload)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EchoProtocol.self]
    return configuration
}

@Test func httpTransportUsesTheAppsCurrentEndpointAndKey() async throws {
    let endpoint = Mutex(InterlaceEndpoint(url: URL(string: "https://first.example.test/proxy/")!))
    let key = Mutex<String?>("first-key")
    let transport = HTTPTransport(configuration: configuration(), key: { key.withLock { $0 } }) { endpoint.withLock { $0 } }
    let request = InterlaceRequest(
        method: .post, path: "/api/downloads/a%2Fb/pause",
        queryItems: [.init(name: "path", value: "Season 1/Film & Cut+#%.mkv")],
        body: Data(#"{"uri":"https://example.test/film"}"#.utf8), contentType: "application/json"
    )
    let first = try await transport.perform(request)
    let echo = try JSONDecoder().decode(Echo.self, from: first.body)
    #expect(first.status == 200)
    #expect(echo.incandenza == nil)
    #expect(echo.authorization == "Bearer first-key")
    #expect(echo.method == "POST" && echo.contentType == "application/json")
    #expect(echo.body == request.body)
    let components = try #require(URLComponents(string: echo.url))
    #expect(components.host == "first.example.test")
    #expect(components.percentEncodedPath == "/proxy/api/downloads/a%2Fb/pause")
    #expect(components.queryItems == [URLQueryItem(name: "path", value: "Season 1/Film & Cut+#%.mkv")])
    #expect(components.percentEncodedQuery?.contains("%2B") == true)
    endpoint.withLock { $0 = InterlaceEndpoint(url: URL(string: "http://second.example.test")!) }
    key.withLock { $0 = "second-key" }
    let second = try await transport.perform(InterlaceRequest(path: "/api/health"))
    let changed = try JSONDecoder().decode(Echo.self, from: second.body)
    #expect(changed.url == "http://second.example.test/api/health")
    #expect(changed.incandenza == nil)
    #expect(changed.authorization == "Bearer second-key")
    #expect(changed.method == "GET" && changed.contentType == nil && changed.body == nil)
    key.withLock { $0 = nil }
    let signedOut = try await transport.perform(InterlaceRequest(path: "/api/health"))
    let unsigned = try JSONDecoder().decode(Echo.self, from: signedOut.body)
    #expect(unsigned.authorization == nil && unsigned.incandenza == nil)
}

@Test func httpTransportLeavesErrorStatusForTheRelay() async throws {
    let transport = HTTPTransport(configuration: configuration(), key: { "test-device-key" }) {
        InterlaceEndpoint(url: URL(string: "http://example.test")!)
    }
    let response = try await transport.perform(InterlaceRequest(path: "/api/unauthorized"))
    #expect(response.status == 401 && !response.body.isEmpty)
}

@Test func thumbnailsUseTheClientsKey() async throws {
    let client = InterlaceClient(configuration: configuration(), key: { "thumbnail-key" }) {
        InterlaceEndpoint(url: URL(string: "https://example.test/proxy/")!)
    }
    let bytes = try await client.thumbnail(path: "/downloads/film.mkv")
    let echo = try JSONDecoder().decode(Echo.self, from: bytes)
    #expect(echo.authorization == "Bearer thumbnail-key" && echo.incandenza == nil)
    #expect(echo.url == "https://example.test/proxy/api/thumbnail?path=/downloads/film.mkv")
}

@Test func inMemoryMultipartUsesTheKey() async throws {
    let transport = HTTPTransport(configuration: configuration(), key: { "multipart-key" }) {
        InterlaceEndpoint(url: URL(string: "http://example.test")!)
    }
    let multipart = try MultipartBody(fields: [], fileName: "film.torrent", contentType: "application/x-bittorrent")
    let request = InterlaceRequest(
        method: .post, path: "/api/downloads/torrent", body: multipart.body(Data([0, 255])),
        contentType: multipart.contentType
    )
    let response = try await transport.perform(request)
    let echo = try JSONDecoder().decode(Echo.self, from: response.body)
    #expect(echo.authorization == "Bearer multipart-key" && echo.incandenza == nil)
    #expect(echo.body == request.body && echo.contentType == multipart.contentType)
}

@Test func httpTransportRequiresAnEndpoint() async {
    let missing = HTTPTransport(configuration: configuration(), key: { "test-device-key" }) { nil }
    await #expect(throws: InterlaceError.notConfigured) {
        try await missing.perform(InterlaceRequest(path: "/api/health"))
    }
}

@Test func malformedPathsProduceAnErrorInsteadOfTrappingFoundation() throws {
    let transport = HTTPTransport(configuration: configuration(), key: { "test-device-key" }) {
        InterlaceEndpoint(url: URL(string: "http://example.test")!)
    }
    for path in ["http://elsewhere.test/api/health", "/api/health?leak=1", "/api/%bad%", "/api/health#fragment", "/api/a b"] {
        #expect(throws: InterlaceError.invalidRequest) { try transport.urlRequest(InterlaceRequest(path: path)) }
    }
}

@Test func multipartIsCopiedToDiskWithBinaryBytesIntact() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("film.mkv")
    let destination = directory.appendingPathComponent("body")
    let bytes = Data(repeating: 0xA5, count: 2 * 1024 * 1024 + 17)
    try bytes.write(to: source)
    let multipart = try MultipartBody(fields: [("path", "Series")], fileName: "film.mkv", contentType: "application/octet-stream")
    try MultipartBody.write(fileURL: source, prefix: multipart.prefix, suffix: multipart.suffix, to: destination)
    #expect(try Data(contentsOf: destination) == multipart.prefix + bytes + multipart.suffix)
    #expect(try Data(contentsOf: source) == bytes)
}

@Test func httpTransportUploadsTheMultipartFileThroughURLSession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("film.mkv")
    let bytes = Data([0, 1, 13, 10, 255])
    try bytes.write(to: file)
    let transport = HTTPTransport(configuration: configuration(), key: { "test-device-key" }) {
        InterlaceEndpoint(url: URL(string: "http://example.test")!)
    }
    let multipart = try MultipartBody(fields: [("path", "Series")], fileName: "film.mkv", contentType: "application/octet-stream")
    let request = InterlaceRequest(method: .post, path: "/api/upload", contentType: multipart.contentType)
    let response = try await transport.upload(request, fromFile: file, prefix: multipart.prefix, suffix: multipart.suffix)
    let echo = try JSONDecoder().decode(Echo.self, from: response.body)
    #expect(echo.incandenza == nil)
    #expect(echo.authorization == "Bearer test-device-key")
    #expect(echo.method == "POST" && echo.contentType == multipart.contentType)
    #expect(echo.body == multipart.prefix + bytes + multipart.suffix)
}

@Test func multipartQuotesUnsafeFileNames() throws {
    let multipart = try MultipartBody(fields: [], fileName: "film\"\r\n%20.mkv", contentType: "application/octet-stream")
    let header = String(decoding: multipart.prefix, as: UTF8.self)
    #expect(header.contains("filename=\"film%22%0D%0A%2520.mkv\""))
    #expect(throws: InterlaceError.invalidRequest) {
        try MultipartBody(fields: [], fileName: "film.mkv", contentType: "video/mp4\r\nInjected: yes")
    }
}
