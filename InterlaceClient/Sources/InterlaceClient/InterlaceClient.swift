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

    public func catalog() async throws -> CatalogResponse {
        try await send(InterlaceRequest(path: "/api/catalog"))
    }

    public func art(titleID: String, kind: ArtKind) async throws -> Data {
        let query: [InterlaceRequest.QueryItem]
        switch kind {
        case .poster:
            query = [.init(name: "kind", value: "poster")]
        case .backdrop:
            query = [.init(name: "kind", value: "backdrop")]
        case .logo:
            query = [.init(name: "kind", value: "logo")]
        case .profile(let personID):
            query = [.init(name: "kind", value: "profile"), .init(name: "person", value: String(personID))]
        case .still(let season, let episode):
            query = [
                .init(name: "kind", value: "still"),
                .init(name: "season", value: String(season)), .init(name: "episode", value: String(episode)),
            ]
        }
        return try Self.checked(await transport.perform(InterlaceRequest(
            path: "/api/art", queryItems: [.init(name: "id", value: titleID)] + query
        )))
    }

    public func searchMatches(titleID: String, query: String? = nil) async throws -> [MatchCandidate] {
        let queryItems = [InterlaceRequest.QueryItem(name: "id", value: titleID)]
            + (query.map { [InterlaceRequest.QueryItem(name: "query", value: $0)] } ?? [])
        return try await send(InterlaceRequest(path: "/api/catalog/search", queryItems: queryItems))
    }

    public func candidatePoster(titleID: String, tmdbID: Int) async throws -> Data {
        try Self.checked(await transport.perform(InterlaceRequest(
            path: "/api/catalog/poster",
            queryItems: [
                .init(name: "id", value: titleID),
                .init(name: "tmdbId", value: String(tmdbID)),
            ]
        )))
    }

    @discardableResult
    public func setMatch(titleID: String, tmdbID: Int) async throws -> CatalogTitle {
        try await send(json("/api/catalog/match", body: MatchRequest(id: titleID, tmdbId: tmdbID)))
    }

    @discardableResult
    public func clearMatch(titleID: String) async throws -> CatalogTitle {
        try await send(json("/api/catalog/match", method: .delete, body: TitleRequest(id: titleID)))
    }

    /// Finishes every file of a title on disk.
    @discardableResult
    public func markWatched(titleID: String) async throws -> OperationResponse {
        try await send(json("/api/catalog/watched", body: TitleRequest(id: titleID)))
    }

    /// Clears the progress of every file of a title on disk.
    @discardableResult
    public func markUnwatched(titleID: String) async throws -> OperationResponse {
        try await send(json("/api/catalog/watched", method: .delete, body: TitleRequest(id: titleID)))
    }

    /// Deletes a title's files; a watched title stays in `CatalogResponse.watched`.
    @discardableResult
    public func deleteTitle(titleID: String) async throws -> OperationResponse {
        try await send(json("/api/catalog/title", method: .delete, body: TitleRequest(id: titleID)))
    }

    public func progress(path: String) async throws -> PlaybackProgress? {
        let response = try await transport.perform(InterlaceRequest(
            path: "/api/progress", queryItems: [.init(name: "path", value: path)]
        ))
        guard response.status != 404 else { return nil }
        let progress: PlaybackProgress = try Self.decode(response)
        return progress
    }

    @discardableResult
    public func saveProgress(path: String, position: Double, duration: Double) async throws -> PlaybackProgress {
        try await send(json("/api/progress", body: ProgressRequest(path: path, position: position, duration: duration)))
    }

    @discardableResult
    public func clearProgress(path: String) async throws -> OperationResponse {
        try await send(json("/api/progress", method: .delete, body: PathRequest(path: path)))
    }

    /// The file's own subtitle choice, else the latest made for another file of its title.
    public func subtitleChoice(path: String) async throws -> SubtitleChoice? {
        let record: SubtitleChoiceRecord = try await send(InterlaceRequest(
            path: "/api/subtitle-choice", queryItems: [.init(name: "path", value: path)]
        ))
        return record.subtitle
    }

    @discardableResult
    public func saveSubtitleChoice(path: String, choice: SubtitleChoice) async throws -> SubtitleChoiceRecord {
        try await send(json("/api/subtitle-choice", body: SubtitleChoiceRequest(path: path, subtitle: choice)))
    }

    /// `progress` gets the fraction of the file sent, from 0 to 1, off the main actor.
    @discardableResult
    public func upload(
        fileURL: URL, to path: String = "", fileName: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadResponse {
        try await upload("/api/upload", fileURL: fileURL, fileName: fileName, fields: [("path", path)], progress: progress)
    }

    @discardableResult
    public func uploadSubtitle(videoPath: String? = nil, fileName: String, data: Data) async throws -> SubtitleUploadResponse {
        try await multipart(
            "/api/upload/subtitle", fileName: fileName, data: data,
            contentType: "text/plain", fields: videoPath.map { [("video_path", $0)] } ?? []
        )
    }

    @discardableResult
    public func uploadSubtitle(videoPath: String? = nil, fileURL: URL) async throws -> SubtitleUploadResponse {
        try await upload(
            "/api/upload/subtitle", fileURL: fileURL,
            contentType: "text/plain", fields: videoPath.map { [("video_path", $0)] } ?? []
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
        contentType: String = "application/octet-stream", fields: [(String, String)] = [],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Response {
        guard let uploadTransport = transport as? any FileUploadTransport else {
            throw InterlaceError.fileUploadUnsupported
        }
        let multipart = try MultipartBody(fields: fields, fileName: fileName ?? fileURL.lastPathComponent, contentType: contentType)
        let request = InterlaceRequest(method: .post, path: path, contentType: multipart.contentType)
        return try Self.decode(await uploadTransport.upload(
            request, fromFile: fileURL, prefix: multipart.prefix, suffix: multipart.suffix, progress: progress
        ))
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
            // Only a string detail is a sentence; FastAPI's validation detail is a list for developers.
            let payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            throw InterlaceError.http(status: response.status, detail: payload?["detail"] as? String ?? "")
        }
    }
}

private struct URIRequest: Encodable { let uri: String }
private struct PathRequest: Encodable { let path: String }
private struct MatchRequest: Encodable { let id: String; let tmdbId: Int }
private struct TitleRequest: Encodable { let id: String }
private struct ProgressRequest: Encodable { let path: String; let position: Double; let duration: Double }
private struct SubtitleChoiceRequest: Encodable { let path: String; let subtitle: SubtitleChoice }
private struct StreamRequest: Encodable { let url: String; let quality: StreamQuality }
private struct SeekRequest: Encodable { let percentage: Double }
private struct SkipRequest: Encodable { let seconds: Int }
private struct VolumeRequest: Encodable { let level: Int }
private struct MuteRequest: Encodable { let muted: Bool }
private struct IndexRequest: Encodable { let index: Int }
private struct SubtitleRequest: Encodable { let value: SubtitleSelection }
private struct DelayRequest: Encodable { let direction: DelayDirection }
