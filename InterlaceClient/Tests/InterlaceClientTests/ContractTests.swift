import Foundation
import Testing
@testable import InterlaceClient

@Test @MainActor func everyRouteBuildsTheBackendContract() async throws {
    let transport = RecordingTransport()
    let client = InterlaceClient(transport: transport)
    _ = try await client.health()
    _ = try await client.version()
    _ = try await client.capabilities()
    _ = try await client.status()
    _ = try await client.systemStats()
    _ = try await client.downloads()
    try await client.addDownload(uri: "magnet:?xt=urn:btih:abc&dn=Example")
    try await client.pauseDownload(gid: "0123456789abcdef")
    try await client.resumeDownload(gid: "0123456789abcdef")
    try await client.removeDownload(gid: "0123456789abcdef")
    _ = try await client.library()
    _ = try await client.library(path: "Series/Season 1 & extras")
    try await client.deleteLibraryItem(path: "/downloads/Series/Episode.mkv")
    #expect(try await client.thumbnail(path: "/downloads/Film & Cut.mkv") == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    try await client.play(path: "/downloads/Series/Episode.mkv")
    try await client.stream(url: "https://example.test/watch?v=1", quality: .compatible)
    try await client.stream(url: "https://example.test/watch?v=1", quality: .p720)
    try await client.stream(url: "https://example.test/watch?v=1")
    _ = try await client.player()
    try await client.playPause()
    try await client.stop()
    try await client.seek(percentage: 42.5)
    try await client.skip(seconds: -30)
    try await client.setVolume(level: 65)
    try await client.setMute(true)
    try await client.setAudio(index: 2)
    try await client.setVideo(index: 1)
    try await client.setSubtitle(.index(3))
    try await client.setSubtitle(.off)
    try await client.setSubtitle(.on)
    try await client.setSubtitle(.next)
    try await client.setSubtitle(.previous)
    try await client.subtitleDelay(.minus)
    try await client.subtitleDelay(.plus)
    try await client.audioDelay(.minus)
    try await client.audioDelay(.plus)

    struct Expected {
        let method: InterlaceRequest.Method
        let path: String
        var query: [InterlaceRequest.QueryItem] = []
        var json: String? = nil
    }
    let expected: [Expected] = [
        .init(method: .get, path: "/api/health"),
        .init(method: .get, path: "/api/version"),
        .init(method: .get, path: "/api/capabilities"),
        .init(method: .get, path: "/api/status"),
        .init(method: .get, path: "/api/system"),
        .init(method: .get, path: "/api/downloads"),
        .init(method: .post, path: "/api/downloads", json: #"{"uri":"magnet:?xt=urn:btih:abc&dn=Example"}"#),
        .init(method: .post, path: "/api/downloads/0123456789abcdef/pause"),
        .init(method: .post, path: "/api/downloads/0123456789abcdef/resume"),
        .init(method: .delete, path: "/api/downloads/0123456789abcdef"),
        .init(method: .get, path: "/api/library"),
        .init(method: .get, path: "/api/library", query: [.init(name: "path", value: "Series/Season 1 & extras")]),
        .init(method: .delete, path: "/api/library", json: #"{"path":"/downloads/Series/Episode.mkv"}"#),
        .init(method: .get, path: "/api/thumbnail", query: [.init(name: "path", value: "/downloads/Film & Cut.mkv")]),
        .init(method: .post, path: "/api/play", json: #"{"path":"/downloads/Series/Episode.mkv"}"#),
        .init(method: .post, path: "/api/stream", json: #"{"url":"https://example.test/watch?v=1","quality":"compatible"}"#),
        .init(method: .post, path: "/api/stream", json: #"{"url":"https://example.test/watch?v=1","quality":"720p"}"#),
        .init(method: .post, path: "/api/stream", json: #"{"url":"https://example.test/watch?v=1","quality":"1080p"}"#),
        .init(method: .get, path: "/api/player"),
        .init(method: .post, path: "/api/player/playpause"),
        .init(method: .post, path: "/api/player/stop"),
        .init(method: .post, path: "/api/player/seek", json: #"{"percentage":42.5}"#),
        .init(method: .post, path: "/api/player/skip", json: #"{"seconds":-30}"#),
        .init(method: .post, path: "/api/player/volume", json: #"{"level":65}"#),
        .init(method: .post, path: "/api/player/mute", json: #"{"muted":true}"#),
        .init(method: .post, path: "/api/player/audio", json: #"{"index":2}"#),
        .init(method: .post, path: "/api/player/video", json: #"{"index":1}"#),
        .init(method: .post, path: "/api/player/subtitle", json: #"{"value":3}"#),
        .init(method: .post, path: "/api/player/subtitle", json: #"{"value":"off"}"#),
        .init(method: .post, path: "/api/player/subtitle", json: #"{"value":"on"}"#),
        .init(method: .post, path: "/api/player/subtitle", json: #"{"value":"next"}"#),
        .init(method: .post, path: "/api/player/subtitle", json: #"{"value":"previous"}"#),
        .init(method: .post, path: "/api/player/subtitle-delay", json: #"{"direction":"minus"}"#),
        .init(method: .post, path: "/api/player/subtitle-delay", json: #"{"direction":"plus"}"#),
        .init(method: .post, path: "/api/player/audio-delay", json: #"{"direction":"minus"}"#),
        .init(method: .post, path: "/api/player/audio-delay", json: #"{"direction":"plus"}"#),
    ]
    let requests = await transport.requests
    #expect(requests.count == expected.count)
    for (request, expected) in zip(requests, expected) {
        #expect(request.method == expected.method)
        #expect(request.path == expected.path)
        #expect(request.queryItems == expected.query)
        if let json = expected.json {
            #expect(request.contentType == "application/json")
            let body = try #require(request.body)
            let actual = try JSONSerialization.jsonObject(with: body) as? NSDictionary
            let wanted = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
            #expect(actual == wanted)
        } else {
            #expect(request.body == nil && request.contentType == nil)
        }
    }
}

@Test func torrentAndSubtitleRequestsContainExactMultipartBytes() async throws {
    let transport = RecordingTransport()
    let client = InterlaceClient(transport: transport)
    let binary = Data([0, 1, 13, 10, 255])
    try await client.uploadTorrent(fileName: "series.torrent", data: binary)
    try await client.uploadSubtitle(videoPath: "/downloads/Series/Episode.mkv", fileName: "Episode.srt", data: binary)
    let requests = await transport.requests
    #expect(requests.map(\.path) == ["/api/downloads/torrent", "/api/upload/subtitle"])
    try expectMultipart(requests[0], body: #require(requests[0].body), fileName: "series.torrent", bytes: binary, contentType: "application/x-bittorrent")
    try expectMultipart(
        requests[1], body: #require(requests[1].body), fileName: "Episode.srt", bytes: binary,
        contentType: "text/plain", fields: [("video_path", "/downloads/Series/Episode.mkv")]
    )
}

@Test func allThreeFileUploadsUseTheStreamingCapability() async throws {
    let transport = RecordingTransport()
    let client = InterlaceClient(transport: transport)
    let file = URL(fileURLWithPath: "/not-opened-by-the-client/Episode.mkv")
    try await client.upload(fileURL: file, to: "Series", fileName: "Season 1/Episode.mkv")
    try await client.uploadTorrent(fileURL: file)
    try await client.uploadSubtitle(videoPath: "/downloads/Series/Episode.mkv", fileURL: file)
    let uploads = await transport.uploads
    #expect(uploads.map(\.request.path) == ["/api/upload", "/api/downloads/torrent", "/api/upload/subtitle"])
    let bytes = Data([0, 1, 255])
    for upload in uploads {
        #expect(upload.fileURL == file)
        #expect(upload.request.body == nil)
    }
    try expectMultipart(
        uploads[0].request, body: uploads[0].prefix + bytes + uploads[0].suffix,
        fileName: "Season 1/Episode.mkv", bytes: bytes, contentType: "application/octet-stream", fields: [("path", "Series")]
    )
    try expectMultipart(
        uploads[1].request, body: uploads[1].prefix + bytes + uploads[1].suffix,
        fileName: "Episode.mkv", bytes: bytes, contentType: "application/x-bittorrent"
    )
    try expectMultipart(
        uploads[2].request, body: uploads[2].prefix + bytes + uploads[2].suffix,
        fileName: "Episode.mkv", bytes: bytes, contentType: "text/plain", fields: [("video_path", "/downloads/Series/Episode.mkv")]
    )
    #expect(await transport.requests.isEmpty)
}

@Test func downloadIDsAreEncodedAsOnePathComponent() async throws {
    let transport = RecordingTransport()
    try await InterlaceClient(transport: transport).pauseDownload(gid: "a/b?c#d%")
    #expect(await transport.requests.first?.path == "/api/downloads/a%2Fb%3Fc%23d%25/pause")
}

@Test func uploadToTheLibraryRootSendsAnEmptyPathField() async throws {
    let transport = RecordingTransport()
    try await InterlaceClient(transport: transport).upload(fileURL: URL(fileURLWithPath: "/film.mkv"))
    let upload = try #require(await transport.uploads.first)
    try expectMultipart(
        upload.request, body: upload.prefix + upload.suffix, fileName: "film.mkv", bytes: Data(),
        contentType: "application/octet-stream", fields: [("path", "")]
    )
}
