import Foundation

public struct InterlaceClient: Sendable {
    private let transport: any Transport

    public init(transport: any Transport) {
        self.transport = transport
    }

    public init(
        configuration: URLSessionConfiguration = HTTPTransport.defaultConfiguration,
        key: @escaping @Sendable () -> String?,
        endpoint: @escaping @Sendable () -> InterlaceEndpoint?
    ) {
        self.init(transport: HTTPTransport(configuration: configuration, key: key, endpoint: endpoint))
    }

    public func health() async throws -> OperationResponse {
        try await send(InterlaceRequest(path: "/api/health"))
    }

    public func version() async throws -> VersionResponse {
        try await send(InterlaceRequest(path: "/api/version"))
    }

    public func capabilities() async throws -> CapabilitiesResponse {
        try await send(InterlaceRequest(path: "/api/capabilities"))
    }

    public func status() async throws -> StatusResponse {
        try await send(InterlaceRequest(path: "/api/status"))
    }

    public func systemStats() async throws -> SystemInfo {
        try await send(InterlaceRequest(path: "/api/system"))
    }

    public func downloads() async throws -> [DownloadItem] {
        try await send(InterlaceRequest(path: "/api/downloads"))
    }

    @discardableResult
    public func addDownload(uri: String) async throws -> DownloadResponse {
        try await send(json("/api/downloads", body: URIRequest(uri: uri)))
    }

    @discardableResult
    public func uploadTorrent(fileName: String, data: Data) async throws -> DownloadResponse {
        try await multipart("/api/downloads/torrent", fileName: fileName, data: data, contentType: "application/x-bittorrent")
    }

    @discardableResult
    public func uploadTorrent(fileURL: URL) async throws -> DownloadResponse {
        try await upload("/api/downloads/torrent", fileURL: fileURL, contentType: "application/x-bittorrent")
    }

    @discardableResult
    public func pauseDownload(gid: String) async throws -> OperationResponse {
        try await send(InterlaceRequest(method: .post, path: "/api/downloads/\(Self.component(gid))/pause"))
    }

    @discardableResult
    public func resumeDownload(gid: String) async throws -> OperationResponse {
        try await send(InterlaceRequest(method: .post, path: "/api/downloads/\(Self.component(gid))/resume"))
    }

    @discardableResult
    public func removeDownload(gid: String) async throws -> OperationResponse {
        try await send(InterlaceRequest(method: .delete, path: "/api/downloads/\(Self.component(gid))"))
    }

    public func library(path: String? = nil) async throws -> LibraryResponse {
        let query = path.map { [InterlaceRequest.QueryItem(name: "path", value: $0)] } ?? []
        return try await send(InterlaceRequest(path: "/api/library", queryItems: query))
    }

    @discardableResult
    public func deleteLibraryItem(path: String) async throws -> OperationResponse {
        try await send(json("/api/library", method: .delete, body: PathRequest(path: path)))
    }

    @discardableResult
    public func upload(fileURL: URL, to path: String = "", fileName: String? = nil) async throws -> UploadResponse {
        try await upload("/api/upload", fileURL: fileURL, fileName: fileName, fields: [("path", path)])
    }

    @discardableResult
    public func uploadSubtitle(videoPath: String, fileName: String, data: Data) async throws -> SubtitleUploadResponse {
        try await multipart(
            "/api/upload/subtitle", fileName: fileName, data: data,
            contentType: "text/plain", fields: [("video_path", videoPath)]
        )
    }

    @discardableResult
    public func uploadSubtitle(videoPath: String, fileURL: URL) async throws -> SubtitleUploadResponse {
        try await upload(
            "/api/upload/subtitle", fileURL: fileURL,
            contentType: "text/plain", fields: [("video_path", videoPath)]
        )
    }

    public func thumbnail(path: String) async throws -> Data {
        try Self.checked(await transport.perform(InterlaceRequest(
            path: "/api/thumbnail", queryItems: [.init(name: "path", value: path)]
        )))
    }

    @discardableResult
    public func play(path: String) async throws -> OperationResponse {
        try await send(json("/api/play", body: PathRequest(path: path)))
    }

    @discardableResult
    public func stream(url: String, quality: StreamQuality = .p1080) async throws -> StreamResponse {
        try await send(json("/api/stream", body: StreamRequest(url: url, quality: quality)))
    }

    public func player() async throws -> PlayerState {
        try await send(InterlaceRequest(path: "/api/player"))
    }

    @discardableResult
    public func playPause() async throws -> OperationResponse {
        try await send(InterlaceRequest(method: .post, path: "/api/player/playpause"))
    }

    @discardableResult
    public func stop() async throws -> OperationResponse {
        try await send(InterlaceRequest(method: .post, path: "/api/player/stop"))
    }

    @discardableResult
    public func seek(percentage: Double) async throws -> OperationResponse {
        try await send(json("/api/player/seek", body: SeekRequest(percentage: percentage)))
    }

    @discardableResult
    public func skip(seconds: Int) async throws -> OperationResponse {
        try await send(json("/api/player/skip", body: SkipRequest(seconds: seconds)))
    }

    @discardableResult
    public func setVolume(level: Int) async throws -> OperationResponse {
        try await send(json("/api/player/volume", body: VolumeRequest(level: level)))
    }

    @discardableResult
    public func setMute(_ muted: Bool) async throws -> OperationResponse {
        try await send(json("/api/player/mute", body: MuteRequest(muted: muted)))
    }

    @discardableResult
    public func setAudio(index: Int) async throws -> OperationResponse {
        try await send(json("/api/player/audio", body: IndexRequest(index: index)))
    }

    @discardableResult
    public func setVideo(index: Int) async throws -> OperationResponse {
        try await send(json("/api/player/video", body: IndexRequest(index: index)))
    }

    @discardableResult
    public func setSubtitle(_ selection: SubtitleSelection) async throws -> OperationResponse {
        try await send(json("/api/player/subtitle", body: SubtitleRequest(value: selection)))
    }

    @discardableResult
    public func subtitleDelay(_ direction: DelayDirection) async throws -> OperationResponse {
        try await send(json("/api/player/subtitle-delay", body: DelayRequest(direction: direction)))
    }

    @discardableResult
    public func audioDelay(_ direction: DelayDirection) async throws -> OperationResponse {
        try await send(json("/api/player/audio-delay", body: DelayRequest(direction: direction)))
    }

    private func send<Response: Decodable>(_ request: InterlaceRequest) async throws -> Response {
        try Self.decode(await transport.perform(request))
    }

    private func json<Body: Encodable>(
        _ path: String, method: InterlaceRequest.Method = .post, body: Body
    ) throws -> InterlaceRequest {
        InterlaceRequest(method: method, path: path, body: try JSONEncoder().encode(body), contentType: "application/json")
    }

    private func multipart<Response: Decodable>(
        _ path: String, fileName: String, data: Data, contentType: String, fields: [(String, String)] = []
    ) async throws -> Response {
        let multipart = try MultipartBody(fields: fields, fileName: fileName, contentType: contentType)
        return try await send(InterlaceRequest(
            method: .post, path: path, body: multipart.body(data), contentType: multipart.contentType
        ))
    }

    private func upload<Response: Decodable>(
        _ path: String, fileURL: URL, fileName: String? = nil,
        contentType: String = "application/octet-stream", fields: [(String, String)] = []
    ) async throws -> Response {
        guard let uploadTransport = transport as? any FileUploadTransport else {
            throw InterlaceError.fileUploadUnsupported
        }
        let multipart = try MultipartBody(fields: fields, fileName: fileName ?? fileURL.lastPathComponent, contentType: contentType)
        let request = InterlaceRequest(method: .post, path: path, contentType: multipart.contentType)
        return try Self.decode(await uploadTransport.upload(request, fromFile: fileURL, prefix: multipart.prefix, suffix: multipart.suffix))
    }

    private static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    private static func decode<Response: Decodable>(_ response: InterlaceResponse) throws -> Response {
        let data = try checked(response)
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw InterlaceError.badResponse }
    }

    private static func checked(_ response: InterlaceResponse) throws -> Data {
        switch response.status {
        case 200..<300: return response.body
        case 401: throw InterlaceError.unauthorized
        default:
            let payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            let detail: String
            if let text = payload?["detail"] as? String {
                detail = text
            } else if let value = payload?["detail"], JSONSerialization.isValidJSONObject(value),
                      let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                detail = String(decoding: encoded, as: UTF8.self)
            } else {
                detail = ""
            }
            throw InterlaceError.http(status: response.status, detail: detail)
        }
    }
}

private struct URIRequest: Encodable { let uri: String }
private struct PathRequest: Encodable { let path: String }
private struct StreamRequest: Encodable { let url: String; let quality: StreamQuality }
private struct SeekRequest: Encodable { let percentage: Double }
private struct SkipRequest: Encodable { let seconds: Int }
private struct VolumeRequest: Encodable { let level: Int }
private struct MuteRequest: Encodable { let muted: Bool }
private struct IndexRequest: Encodable { let index: Int }
private struct SubtitleRequest: Encodable { let value: SubtitleSelection }
private struct DelayRequest: Encodable { let direction: DelayDirection }
