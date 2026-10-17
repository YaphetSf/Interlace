import Foundation
import Testing
@testable import InterlaceClient

@Test func serverMetadataFixturesDecode() throws {
    #expect(try decodeFixture("ok", as: OperationResponse.self).ok)
    let version = try decodeFixture("version", as: VersionResponse.self)
    #expect(version.service == "interlace")
    #expect(version.version == "0.1.0")
    let status = try decodeFixture("status", as: StatusResponse.self)
    #expect(status.ok)
    #expect(status.service == "interlace")
    #expect(status.api.basePath == "/api")
    #expect(status.api.requestBaseUrl == "http://interlace:8000")
    #expect(status.server.downloadDirConfigured && status.server.downloadDirExists)
    let capabilities = try decodeFixture("capabilities", as: CapabilitiesResponse.self)
    #expect(capabilities.api.basePath == "/api")
    #expect(capabilities.service == "interlace")
    #expect(capabilities.connectionModes == ["lan", "private_network", "private_reverse_proxy"])
    #expect(capabilities.features.downloads.addUri && capabilities.features.downloads.addTorrent)
    #expect(capabilities.features.downloads.uploadFile && capabilities.features.downloads.pauseResumeRemove)
    #expect(capabilities.features.library.scanDownloadDir && capabilities.features.library.playLocalFile)
    let playback = capabilities.features.playback
    #expect(playback.streamQualities == [.compatible, .p720, .p1080])
    #expect(playback.streamUrl && playback.websiteUrlResolution && playback.playPauseStop && playback.seek)
    #expect(playback.volume && playback.mute && playback.audioStreams && playback.videoStreams && playback.subtitles)
    #expect(playback.audioDelay && playback.subtitleDelay)
    #expect(!capabilities.features.discovery.bonjour && capabilities.features.discovery.manualBaseUrl)
}

@Test func downloadAndLibraryFixturesDecodeWithoutLosingSizes() throws {
    let downloads = try decodeFixture("downloads", as: [DownloadItem].self)
    #expect(downloads[0].id == "0123456789abcdef")
    #expect(downloads[0].isTorrent && downloads[0].error == nil)
    #expect(downloads[0].total == 8589934592 && downloads[0].completed == 4294967296)
    #expect(downloads[0].progress == 50 && downloads[0].speed == 1048576)
    #expect(downloads[1].status == "error" && downloads[1].error == "Resource not found")
    #expect(!downloads[1].isTorrent && downloads[1].total == 0)
    #expect(try decodeFixture("download", as: DownloadResponse.self).gid == downloads[0].gid)
    let library = try decodeFixture("library", as: LibraryResponse.self)
    #expect(library.items[0].isDirectory)
    #expect(library.items[0].size == nil && library.items[0].thumbnail == nil)
    #expect(library.items[1].id == "/downloads/Film & Cut.mkv")
    #expect(library.items[1].rel == "Film & Cut.mkv" && library.items[1].size == 8589934592)
    #expect(library.items[1].thumbnail == "/api/thumbnail?path=/downloads/Film%20%26%20Cut.mkv")
    #expect(library.disk.total == 1000000000000 && library.disk.percent == 40)
    let upload = try decodeFixture("upload", as: UploadResponse.self)
    #expect(upload.ok && upload.filename == "Series/Episode.mkv")
    let subtitle = try decodeFixture("subtitle-upload", as: SubtitleUploadResponse.self)
    #expect(subtitle.ok && subtitle.filename == "Episode.srt" && !subtitle.activated)
}

@Test func systemAndStreamFixturesDecode() throws {
    let system = try decodeFixture("system", as: SystemInfo.self)
    #expect(system.cpu.percent == 12.5 && system.cpu.temp == nil)
    #expect(system.memory.total == 8589934592 && system.memory.percent == 25)
    #expect(system.network.downloadSpeed == 1048576 && system.network.uploadSpeed == 4096)
    #expect(system.uptime == 3600)
    let stream = try decodeFixture("stream", as: StreamResponse.self)
    #expect(stream.ok && stream.title == "An episode" && stream.source == "youtube" && stream.quality == "1080p")
}

@Test func activePlayerFixtureDecodesKodiStreamObjects() throws {
    let player = try decodeFixture("player-active", as: PlayerState.self)
    #expect(player.active && player.playerID == 1)
    #expect(player.title == "An episode" && player.file == "/downloads/Series/Episode.mkv")
    #expect(player.percentage == 25.5 && player.time == 120 && player.totalTime == 480 && player.speed == 1)
    #expect(player.volume == 65 && player.muted == false)
    #expect(player.currentAudioIndex == 0 && player.currentAudioStream?.channels == 2)
    #expect(player.currentAudioStream?.language == "eng" && player.currentAudioStream?.codec == "aac")
    #expect(player.currentVideoIndex == 0 && player.currentVideoStream?.codec == "hevc")
    #expect(player.currentVideoStream?.width == 1920 && player.currentVideoStream?.height == 1080)
    #expect(player.subtitles.map(\.index) == [0, 1])
    #expect(player.currentSubtitleIndex == 1 && player.subtitleEnabled)
    #expect(player.audioStreams.first?.id == 0)
}

@Test func inactiveAndEmptyStreamPlayerFixturesDecode() throws {
    let inactive = try decodeFixture("player-inactive", as: PlayerState.self)
    #expect(!inactive.active && inactive.volume == 65 && inactive.muted == true)
    #expect(inactive.playerID == nil && inactive.file == nil && inactive.title == nil)
    #expect(inactive.time == 0 && inactive.totalTime == 0 && inactive.percentage == 0 && inactive.speed == 0)
    #expect(inactive.audioStreams.isEmpty && inactive.videoStreams.isEmpty && inactive.subtitles.isEmpty)
    let empty = try decodeFixture("player-empty-streams", as: PlayerState.self)
    #expect(empty.active && empty.speed == 0)
    #expect(empty.currentAudioStream == nil && empty.currentVideoStream == nil && empty.currentSubtitle == nil)
    #expect(empty.volume == nil && empty.muted == nil && !empty.subtitleEnabled)
}

@Test func metadataReportsTheXPersonHeader() throws {
    let capabilities = try decodeFixture("capabilities", as: CapabilitiesResponse.self)
    let status = try decodeFixture("status", as: StatusResponse.self)
    for auth in [capabilities.api.auth, status.auth] {
        #expect(auth.required && !auth.pairing && auth.scheme == "x-person")
    }
}
