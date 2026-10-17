import Foundation
import Testing
@testable import InterlaceClient

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func decodeFixture<Value: Decodable>(_ name: String, as type: Value.Type) throws -> Value {
    try JSONDecoder().decode(type, from: fixture(name))
}

struct FixedTransport: Transport {
    let response: InterlaceResponse

    func perform(_ request: InterlaceRequest) async throws -> InterlaceResponse { response }
}

actor RecordingTransport: FileUploadTransport {
    struct Upload: Sendable {
        let request: InterlaceRequest
        let fileURL: URL
        let prefix: Data
        let suffix: Data
    }

    private(set) var requests: [InterlaceRequest] = []
    private(set) var uploads: [Upload] = []

    func perform(_ request: InterlaceRequest) throws -> InterlaceResponse {
        requests.append(request)
        return try response(for: request)
    }

    func upload(_ request: InterlaceRequest, fromFile fileURL: URL, prefix: Data, suffix: Data) throws -> InterlaceResponse {
        uploads.append(Upload(request: request, fileURL: fileURL, prefix: prefix, suffix: suffix))
        return try response(for: request)
    }

    private func response(for request: InterlaceRequest) throws -> InterlaceResponse {
        let name: String
        switch (request.method, request.path) {
        case (.get, "/api/health"): name = "ok"
        case (.get, "/api/version"): name = "version"
        case (.get, "/api/status"): name = "status"
        case (.get, "/api/capabilities"): name = "capabilities"
        case (.get, "/api/system"): name = "system"
        case (.get, "/api/downloads"): name = "downloads"
        case (.post, "/api/downloads"), (.post, "/api/downloads/torrent"): name = "download"
        case (.get, "/api/library"): name = "library"
        case (.post, "/api/upload"): name = "upload"
        case (.post, "/api/upload/subtitle"): name = "subtitle-upload"
        case (.post, "/api/stream"): name = "stream"
        case (.get, "/api/player"): name = "player-active"
        case (.get, "/api/thumbnail"): return InterlaceResponse(status: 200, body: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        default: name = "ok"
        }
        return InterlaceResponse(status: 200, body: try fixture(name))
    }
}

func expectMultipart(
    _ request: InterlaceRequest, body: Data, fileName: String, bytes: Data,
    contentType: String, fields: [(String, String)] = []
) throws {
    #expect(request.method == .post)
    #expect(request.queryItems.isEmpty)
    let header = try #require(request.contentType)
    #expect(header.hasPrefix("multipart/form-data; boundary="))
    let boundary = try #require(header.components(separatedBy: "boundary=").last)
    var expected = Data()
    for (name, value) in fields {
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
    expected.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
    expected.append(bytes)
    expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
    #expect(body == expected)
}
