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
    #expect(capabilities.connectionModes == ["lan", "private_network"])
    #expect(capabilities.features.downloads.addUri && capabilities.features.downloads.addTorrent)
    #expect(capabilities.features.downloads.uploadFile && capabilities.features.downloads.pauseResumeRemove)
    #expect(capabilities.features.library.scanDownloadDir && capabilities.features.library.playLocalFile)
    let catalog = capabilities.features.catalog
    #expect(catalog.titles && !catalog.art && catalog.progress && catalog.fileStreaming)
    let playback = capabilities.features.playback
    #expect(playback.streamQualities == [.compatible, .p720, .p1080])
    #expect(playback.streamUrl && playback.websiteUrlResolution && playback.playPauseStop && playback.seek)
    #expect(playback.volume && playback.mute && playback.audioStreams && playback.videoStreams && playback.subtitles)
    #expect(playback.audioDelay && playback.subtitleDelay)
    #expect(!capabilities.features.discovery.bonjour && capabilities.features.discovery.manualBaseUrl)
}

@Test func catalogFixtureDecodesEveryField() throws {
    let catalog = try decodeFixture("catalog", as: CatalogResponse.self)
    #expect(catalog.titles.count == 2)
    let movie = catalog.titles[0]
    #expect(movie.id == "Unmatched.1080p.mkv" && movie.kind == .movie && movie.title == "Unmatched")
    #expect(movie.year == nil && movie.overview == nil && movie.tmdbId == nil && movie.matched == nil)
    #expect(!movie.poster && !movie.backdrop && !movie.logo && movie.added == 1763424000)
    #expect(movie.runtime == nil && movie.certification == nil)
    #expect(movie.genres.isEmpty && movie.crew.isEmpty && movie.cast.isEmpty)
    #expect(movie.files.count == 1)
    let movieFile = try #require(movie.files.first)
    #expect(movieFile.path == "/downloads/Unmatched.1080p.mkv" && movieFile.id == movieFile.path)
    #expect(movieFile.name == "Unmatched.1080p.mkv" && movieFile.size == 8589934592)
    #expect(movieFile.season == nil && movieFile.episode == nil && movieFile.episodeTitle == nil)
    #expect(movieFile.episodeOverview == nil && movieFile.airDate == nil && movieFile.runtime == nil)
    #expect(!movieFile.still && movieFile.media == nil)
    #expect(movieFile.subtitles.isEmpty && movieFile.progress == nil)

    let show = catalog.titles[1]
    let showID = "The.Office.US.S02.1080p.BluRay.x265-RARBG"
    let episodeName = "The.Office.US.S02E01.1080p.BluRay.x265-RARBG.mkv"
    let episodePath = "/downloads/\(showID)/\(episodeName)"
    #expect(show.id == showID && show.kind == .show && show.title == "The Office")
    #expect(show.year == 2005 && show.tmdbId == 2316 && show.matched == .auto)
    #expect(show.overview == "A mockumentary on a group of typical office workers.")
    #expect(show.poster && show.backdrop && show.logo && show.added == 1763251200)
    #expect(show.runtime == 22 && show.certification == "15" && show.genres == ["Comedy"])
    #expect(show.crew.count == 1 && show.cast.count == 1)
    let creator = try #require(show.crew.first)
    #expect(creator.personId == 35796 && creator.name == "Greg Daniels")
    #expect(creator.job == "Creator" && creator.profile)
    let castMember = try #require(show.cast.first)
    #expect(castMember.personId == 17419 && castMember.name == "Steve Carell")
    #expect(castMember.character == "Michael Scott" && castMember.profile)
    #expect(show.files.count == 2)
    let episode = show.files[0]
    #expect(episode.path == episodePath && episode.id == episode.path)
    #expect(episode.name == episodeName && episode.size == 734003200)
    #expect(episode.season == 2 && episode.episode == 1 && episode.episodeTitle == "The Dundies")
    #expect(episode.episodeOverview == "Michael hosts the annual office awards at a local restaurant.")
    #expect(episode.airDate == "2005-09-20" && episode.runtime == 22 && episode.still)
    let media = try #require(episode.media)
    #expect(media.duration == 1318.4)
    #expect(media.video.codec == "hevc" && media.video.width == 1920 && media.video.height == 1080)
    #expect(media.video.bitDepth == 10 && media.video.hdr == nil)
    #expect(media.audio.count == 1 && media.subtitles.count == 1)
    let audio = try #require(media.audio.first)
    #expect(audio.codec == "aac" && audio.channels == 2 && audio.language == "eng")
    #expect(audio.title == nil && !audio.atmos && audio.default)
    let embeddedSubtitle = try #require(media.subtitles.first)
    #expect(embeddedSubtitle.codec == "subrip" && embeddedSubtitle.language == "eng")
    #expect(embeddedSubtitle.title == "English" && !embeddedSubtitle.forced)
    #expect(episode.subtitles.count == 1)
    let subtitle = try #require(episode.subtitles.first)
    let subtitleName = "The.Office.US.S02E01.1080p.BluRay.x265-RARBG-cn.srt"
    #expect(subtitle.path == "/downloads/\(showID)/\(subtitleName)" && subtitle.id == subtitle.path)
    #expect(subtitle.name == subtitleName && subtitle.label == "cn")
    let progress = try #require(episode.progress)
    #expect(progress.path == nil && progress.position == 754.2 && progress.duration == 1320)
    #expect(!progress.finished && progress.updated == 1763337600)
    let nextEpisode = show.files[1]
    let nextName = "The.Office.US.S02E02.1080p.BluRay.x265-RARBG.mkv"
    #expect(nextEpisode.path == "/downloads/\(showID)/\(nextName)" && nextEpisode.id == nextEpisode.path)
    #expect(nextEpisode.name == nextName && nextEpisode.size == 735051776)
    #expect(nextEpisode.season == 2 && nextEpisode.episode == 2 && nextEpisode.episodeTitle == nil)
    #expect(nextEpisode.episodeOverview == nil && nextEpisode.airDate == nil && nextEpisode.runtime == nil)
    #expect(!nextEpisode.still && nextEpisode.media == nil)
    #expect(nextEpisode.subtitles.isEmpty && nextEpisode.progress == nil)
    #expect(catalog.continueWatching.count == 1)
    let item = try #require(catalog.continueWatching.first)
    #expect(item.titleId == showID && item.path == episodePath)

    let encoded = try JSONEncoder().encode(catalog)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json["continue"] != nil && json["continueWatching"] == nil)
    #expect(try JSONDecoder().decode(CatalogResponse.self, from: encoded) == catalog)
}

@Test(arguments: [
    ("dolbyVision", HDRFormat.dolbyVision), ("hdr10plus", HDRFormat.hdr10plus),
    ("hdr10", HDRFormat.hdr10), ("hlg", HDRFormat.hlg),
])
func catalogMediaDecodesHDRAndStreamMetadata(rawValue: String, hdr: HDRFormat) throws {
    let data = Data("""
        {
          "duration": 7200.5,
          "video": {"codec": "hevc", "width": 3840, "height": 2160, "bitDepth": 10, "hdr": "\(rawValue)"},
          "audio": [
            {"codec": "truehd", "channels": 8, "language": null, "title": "Dolby Atmos", "atmos": true, "default": false},
            {"codec": "aac", "channels": 2, "language": "eng", "title": null, "atmos": false, "default": true}
          ],
          "subtitles": [{"codec": "hdmv_pgs_subtitle", "language": null, "title": null, "forced": true}]
        }
        """.utf8)
    let media = try JSONDecoder().decode(CatalogMedia.self, from: data)
    #expect(media.duration == 7200.5 && media.video.hdr == hdr)
    #expect(media.video.width == 3840 && media.video.height == 2160)
    #expect(media.audio.map(\.codec) == ["truehd", "aac"])
    let atmos = try #require(media.audio.first)
    #expect(atmos.channels == 8 && atmos.language == nil && atmos.title == "Dolby Atmos")
    #expect(atmos.atmos && !atmos.default)
    let subtitle = try #require(media.subtitles.first)
    #expect(subtitle.codec == "hdmv_pgs_subtitle" && subtitle.forced)
    #expect(subtitle.language == nil && subtitle.title == nil)
    let encoded = try JSONEncoder().encode(media)
    #expect(try JSONDecoder().decode(CatalogMedia.self, from: encoded) == media)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let video = try #require(json["video"] as? [String: Any])
    #expect(video["hdr"] as? String == rawValue)
}

@Test func catalogMediaAllowsEmptyStreamLists() throws {
    let data = Data(#"{"duration": 10, "video": {"codec": "h264", "width": 1920, "height": 1080, "bitDepth": 8, "hdr": null}, "audio": [], "subtitles": []}"#.utf8)
    let media = try JSONDecoder().decode(CatalogMedia.self, from: data)
    #expect(media.video.hdr == nil && media.audio.isEmpty && media.subtitles.isEmpty)
}

@Test func unknownHDRFormatsFailDecoding() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(HDRFormat.self, from: Data(#""hdr10+""#.utf8))
    }
}

@Test func matchFixturesDecodeCandidatesAndManualMatches() throws {
    let candidates = try decodeFixture("catalog-search", as: [MatchCandidate].self)
    #expect(candidates.count == 2)
    let candidate = try #require(candidates.first)
    #expect(candidate.id == 10491 && candidate.tmdbId == 10491)
    #expect(candidate.title == "Unmatched" && candidate.year == 2003 && candidate.poster)
    #expect(candidate.overview == "A kickboxing champion returns to the ring for one last fight.")
    let bare = candidates[1]
    #expect(bare.tmdbId == 440962 && bare.title == "Unmatched")
    #expect(bare.year == nil && bare.overview == nil && !bare.poster)
    let encodedCandidates = try JSONEncoder().encode(candidates)
    let candidateJSON = try #require(JSONSerialization.jsonObject(with: encodedCandidates) as? [[String: Any]])
    #expect(candidateJSON[0]["tmdbId"] != nil && candidateJSON[0]["tmdbID"] == nil)

    let title = try decodeFixture("catalog-match", as: CatalogTitle.self)
    #expect(title.id == "Unmatched.1080p.mkv" && title.kind == .movie)
    #expect(title.tmdbId == 10491 && title.matched == .manual)
    #expect(title.poster && title.backdrop && !title.logo)
    let director = try #require(title.crew.first)
    #expect(director.personId == 10980 && director.name == "Jesse Vail")
    #expect(director.job == "Director" && !director.profile)
    let lead = try #require(title.cast.first)
    #expect(lead.personId == 54321 && lead.character == "The Champion" && !lead.profile)
    let encodedTitle = try JSONEncoder().encode(title)
    let titleJSON = try #require(JSONSerialization.jsonObject(with: encodedTitle) as? [String: Any])
    #expect(titleJSON["matched"] as? String == "manual")
    #expect(try JSONDecoder().decode(CatalogTitle.self, from: encodedTitle) == title)
}

@Test func unknownMatchSourcesFailDecoding() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(MatchSource.self, from: Data(#""automatic""#.utf8))
    }
}

@Test func progressFixtureIncludesItsPathAndServerTimestamp() throws {
    let progress = try decodeFixture("progress", as: PlaybackProgress.self)
    #expect(progress.path == "/downloads/The.Office.US.S02.1080p.BluRay.x265-RARBG/The.Office.US.S02E01.1080p.BluRay.x265-RARBG.mkv")
    #expect(progress.position == 754.2 && progress.duration == 1320)
    #expect(!progress.finished && progress.updated == 1763337600)
}

@Test func subtitleChoicesDecodeEveryKindAndRejectOthers() throws {
    let decoder = JSONDecoder()
    func decode(_ json: String) throws -> SubtitleChoiceRecord {
        try decoder.decode(SubtitleChoiceRecord.self, from: Data(#"{"path":"/downloads/a.mkv","subtitle":\#(json)}"#.utf8))
    }
    #expect(try decode(#"{"kind":"off"}"#).subtitle == .off)
    #expect(try decode(#"{"kind":"sidecar","label":""}"#).subtitle == .sidecar(label: ""))
    #expect(try decode(#"{"kind":"stream","index":3,"language":"eng"}"#).subtitle == .stream(index: 3, language: "eng"))
    #expect(try decode(#"{"kind":"stream","index":2}"#).subtitle == .stream(index: 2, language: nil))
    #expect(try decode("null").subtitle == nil)
    #expect(throws: DecodingError.self) { try decode(#"{"kind":"embedded","index":1}"#) }
    let fixture = try decodeFixture("subtitle-choice", as: SubtitleChoiceRecord.self)
    #expect(fixture.subtitle == .sidecar(label: "cn"))
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

@Test func metadataReportsDeviceKeyAuthenticationAndLANAccess() throws {
    let capabilities = try decodeFixture("capabilities", as: CapabilitiesResponse.self)
    let status = try decodeFixture("status", as: StatusResponse.self)
    #expect(capabilities.auth == "device-key" && capabilities.lan)
    #expect(status.auth.required && !status.auth.pairing && status.auth.scheme == "device-key")
}
