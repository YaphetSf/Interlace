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
    await #expect(throws: InterlaceError.http(status: 404, detail: "")) {
        try await client(status: 404).art(titleID: "missing", kind: .poster)
    }
    await #expect(throws: InterlaceError.unauthorized) {
        try await client(status: 401).art(titleID: "The Office", kind: .backdrop)
    }
    await #expect(throws: InterlaceError.http(status: 422, detail: "")) {
        try await client(status: 422, body: fixture("validation-error")).health()
    }
    let created = try await client(status: 201, body: fixture("ok")).health()
    #expect(created.ok)
    #expect(InterlaceError.unauthorized.localizedDescription == "Not accepted")
    #expect(InterlaceError.http(status: 502, detail: "kodi: offline").localizedDescription == "kodi: offline")
    #expect(InterlaceError.notConfigured.localizedDescription == "No Interlace server configured")
    #expect(InterlaceError.http(status: 422, detail: "").localizedDescription == "Interlace rejected the request")
    #expect(InterlaceError.http(status: 404, detail: "").localizedDescription == "Not found on Interlace")
    #expect(InterlaceError.http(status: 502, detail: "").localizedDescription == "Interlace is unavailable")
    #expect(InterlaceError.http(status: 500, detail: "").localizedDescription == "Interlace hit an error")
}

@Test func progressReturnsNilOnlyForNotFound() async throws {
    let missing = InterlaceClient(transport: FixedTransport(response: .init(status: 404, body: Data())))
    #expect(try await missing.progress(path: "/downloads/missing.mkv") == nil)
    let failed = InterlaceClient(transport: FixedTransport(response: .init(status: 500, body: Data(#"{"detail":"storage unavailable"}"#.utf8))))
    await #expect(throws: InterlaceError.http(status: 500, detail: "storage unavailable")) {
        try await failed.progress(path: "/downloads/film.mkv")
    }
    let unauthorized = InterlaceClient(transport: FixedTransport(response: .init(status: 401, body: Data())))
    await #expect(throws: InterlaceError.unauthorized) {
        try await unauthorized.progress(path: "/downloads/film.mkv")
    }
    let malformed = InterlaceClient(transport: FixedTransport(response: .init(status: 200, body: Data("null".utf8))))
    await #expect(throws: InterlaceError.badResponse) {
        try await malformed.progress(path: "/downloads/film.mkv")
    }
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
    let contentLength: String?
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
            payload["contentLength"] = request.value(forHTTPHeaderField: "Content-Length")
            payload["body"] = request.httpBody?.base64EncodedString()
            if let stream = request.httpBodyStream {
                payload["body"] = try readAll(stream).base64EncodedString()
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

/// Never answers, so only cancellation ends the request.
private final class SilentProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private func readAll(_ stream: InputStream) throws -> Data {
    stream.open()
    defer { stream.close() }
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw stream.streamError ?? InterlaceError.badResponse }
        if count == 0 { return bytes }
        bytes.append(contentsOf: buffer.prefix(count))
    }
}

private func configuration(_ protocolClass: AnyClass = EchoProtocol.self) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
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
    #expect(throws: InterlaceError.notConfigured) {
        try missing.fileRequest(path: "/downloads/film.mkv")
    }
    await #expect(throws: InterlaceError.notConfigured) {
        try await missing.perform(InterlaceRequest(path: "/api/health"))
    }
}

@Test func fileRequestsUseTheBasePathAndEncodeAuthenticatedQueries() throws {
    let transport = HTTPTransport(configuration: configuration(), key: { "file-key" }) {
        InterlaceEndpoint(url: URL(string: "https://example.test/proxy/")!)
    }
    let path = "/downloads/Season 1/Film & Cut+.mkv"
    let request = try transport.fileRequest(path: path)
    let url = try #require(request.url)
    #expect(url.absoluteString == "https://example.test/proxy/api/file?path=/downloads/Season%201/Film%20%26%20Cut%2B.mkv")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.percentEncodedPath == "/proxy/api/file")
    #expect(components.queryItems == [URLQueryItem(name: "path", value: path)])
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer file-key")
    #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
    #expect(request.httpBody == nil && request.value(forHTTPHeaderField: "Content-Type") == nil)
}

@Test func malformedPathsProduceAnErrorInsteadOfTrappingFoundation() throws {
    let transport = HTTPTransport(configuration: configuration(), key: { "test-device-key" }) {
        InterlaceEndpoint(url: URL(string: "http://example.test")!)
    }
    for path in ["http://elsewhere.test/api/health", "/api/health?leak=1", "/api/%bad%", "/api/health#fragment", "/api/a b"] {
        #expect(throws: InterlaceError.invalidRequest) { try transport.urlRequest(InterlaceRequest(path: path)) }
    }
}

private func temporaryFile(_ bytes: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("film.mkv")
    try bytes.write(to: file)
    return file
}

@Test func multipartStreamsFromTheFileWithBinaryBytesIntact() throws {
    let bytes = Data((0..<(2 * MultipartFileStream.chunk + 17)).map { UInt8(truncatingIfNeeded: $0 * 7) })
    let file = try temporaryFile(bytes)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let multipart = try MultipartBody(fields: [("path", "Series")], fileName: "film.mkv", contentType: "application/octet-stream")
    let body = try MultipartFileBody(fileURL: file, prefix: multipart.prefix, suffix: multipart.suffix)
    let expected = multipart.prefix + bytes + multipart.suffix
    #expect(body.length == Int64(expected.count))
    #expect(try readAll(body.stream()) == expected)
    #expect(try readAll(body.stream()) == expected)
    #expect(throws: InterlaceError.invalidRequest) {
        try MultipartFileBody(fileURL: URL(string: "https://example.test/film.mkv")!, prefix: Data(), suffix: Data())
    }
}

@Test func aStoppedMultipartStreamEndsWithoutTheRestOfTheFile() throws {
    let bytes = Data(repeating: 0x5A, count: 16 * MultipartFileStream.chunk)
    let file = try temporaryFile(bytes)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let body = try MultipartFileBody(fileURL: file, prefix: Data("head".utf8), suffix: Data("tail".utf8))
    let stream = try body.stream()
    stream.open()
    defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 4096)
    #expect(stream.read(&buffer, maxLength: buffer.count) > 0)
    body.stop()
    var total = 0
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        total += count
    }
    #expect(total < bytes.count)
}

@Test func uploadProgressReportsEachNewTenthOfAPercent() throws {
    let file = try temporaryFile(Data([1]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let reported = Mutex<[Double]>([])
    let delegate = UploadDelegate(
        body: try MultipartFileBody(fileURL: file, prefix: Data(), suffix: Data()),
        progress: { fraction in reported.withLock { $0.append(fraction) } }
    )
    let task = URLSession.shared.dataTask(with: URL(string: "http://example.test/api/upload")!)
    for sent: Int64 in [0, 1, 2, 500_000, 500_001, 999_999, 1_000_000] {
        delegate.urlSession(.shared, task: task, didSendBodyData: 1, totalBytesSent: sent, totalBytesExpectedToSend: 1_000_000)
    }
    #expect(reported.withLock { $0 } == [0.5, 0.999, 1])
}

@Test func cancellingTheTaskCancelsAnUpload() async throws {
    let file = try temporaryFile(Data(repeating: 1, count: 4 * MultipartFileStream.chunk))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HTTPTransport(configuration: configuration(SilentProtocol.self), key: { "test-device-key" }) {
        InterlaceEndpoint(url: URL(string: "http://example.test")!)
    }
    let multipart = try MultipartBody(fields: [], fileName: "film.mkv", contentType: "application/octet-stream")
    let request = InterlaceRequest(method: .post, path: "/api/upload", contentType: multipart.contentType)
    let upload = Task {
        try await transport.upload(request, fromFile: file, prefix: multipart.prefix, suffix: multipart.suffix, progress: nil)
    }
    try await Task.sleep(for: .milliseconds(100))
    upload.cancel()
    await #expect(throws: CancellationError.self) { try await upload.value }
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
    let response = try await transport.upload(request, fromFile: file, prefix: multipart.prefix, suffix: multipart.suffix, progress: nil)
    let echo = try JSONDecoder().decode(Echo.self, from: response.body)
    let body = multipart.prefix + bytes + multipart.suffix
    #expect(echo.incandenza == nil)
    #expect(echo.authorization == "Bearer test-device-key")
    #expect(echo.method == "POST" && echo.contentType == multipart.contentType)
    #expect(echo.contentLength == String(body.count))
    #expect(echo.body == body)
}

@Test func multipartQuotesUnsafeFileNames() throws {
    let multipart = try MultipartBody(fields: [], fileName: "film\"\r\n%20.mkv", contentType: "application/octet-stream")
    let header = String(decoding: multipart.prefix, as: UTF8.self)
    #expect(header.contains("filename=\"film%22%0D%0A%2520.mkv\""))
    #expect(throws: InterlaceError.invalidRequest) {
        try MultipartBody(fields: [], fileName: "film.mkv", contentType: "video/mp4\r\nInjected: yes")
    }
}
