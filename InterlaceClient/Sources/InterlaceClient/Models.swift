import Foundation

public struct OperationResponse: Codable, Equatable, Sendable {
    public let ok: Bool
}

public struct VersionResponse: Codable, Equatable, Sendable {
    public let service: String
    public let version: String
}

public struct AuthStatus: Codable, Equatable, Sendable {
    public let required: Bool
    public let pairing: Bool
    public let scheme: String
}

public struct StatusResponse: Codable, Equatable, Sendable {
    public struct API: Codable, Equatable, Sendable {
        public let basePath: String
        public let requestBaseUrl: String
    }

    public struct Server: Codable, Equatable, Sendable {
        public let downloadDirConfigured: Bool
        public let downloadDirExists: Bool
    }

    public let ok: Bool
    public let service: String
    public let version: String
    public let api: API
    public let server: Server
    public let auth: AuthStatus
}

public struct CapabilitiesResponse: Codable, Equatable, Sendable {
    public struct API: Codable, Equatable, Sendable {
        public let basePath: String
    }

    public struct Features: Codable, Equatable, Sendable {
        public struct Downloads: Codable, Equatable, Sendable {
            public let addUri: Bool
            public let addTorrent: Bool
            public let uploadFile: Bool
            public let pauseResumeRemove: Bool
        }

        public struct Library: Codable, Equatable, Sendable {
            public let scanDownloadDir: Bool
            public let playLocalFile: Bool
        }

        public struct Catalog: Codable, Equatable, Sendable {
            public let titles: Bool
            public let art: Bool
            public let progress: Bool
            public let fileStreaming: Bool
        }

        public struct Playback: Codable, Equatable, Sendable {
            public let streamUrl: Bool
            public let websiteUrlResolution: Bool
            public let streamQualities: [StreamQuality]
            public let playPauseStop: Bool
            public let seek: Bool
            public let volume: Bool
            public let mute: Bool
            public let audioStreams: Bool
            public let videoStreams: Bool
            public let subtitles: Bool
            public let audioDelay: Bool
            public let subtitleDelay: Bool
        }

        public struct Discovery: Codable, Equatable, Sendable {
            public let bonjour: Bool
            public let manualBaseUrl: Bool
        }

        public let downloads: Downloads
        public let library: Library
        public let catalog: Catalog
        public let playback: Playback
        public let discovery: Discovery
    }

    public let service: String
    public let api: API
    public let auth: String
    public let lan: Bool
    public let connectionModes: [String]
    public let features: Features
}

public struct DownloadResponse: Codable, Equatable, Sendable {
    public let gid: String
}

public struct DownloadItem: Codable, Equatable, Identifiable, Sendable {
    public let gid: String
    public let name: String
    public let status: String
    public let total: Int64
    public let completed: Int64
    public let progress: Double
    public let speed: Int64
    public let isTorrent: Bool
    public let error: String?

    public var id: String { gid }

    enum CodingKeys: String, CodingKey {
        case gid, name, status, total, completed, progress, speed, error
        case isTorrent = "is_torrent"
    }
}

public struct LibraryResponse: Codable, Equatable, Sendable {
    public let items: [LibraryItem]
    public let disk: DiskInfo
}

public enum LibraryItemType: String, Codable, Sendable {
    case file, directory
}

public struct LibraryItem: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let type: LibraryItemType
    public let path: String
    public let rel: String
    public let size: Int64?
    public let thumbnail: String?

    public var id: String { path }
    public var isDirectory: Bool { type == .directory }
}

public struct DiskInfo: Codable, Equatable, Sendable {
    public let total: Int64
    public let used: Int64
    public let free: Int64
    public let percent: Double
}

public struct CatalogResponse: Codable, Equatable, Sendable {
    /// Unwatched titles on disk, newest first.
    public let titles: [CatalogTitle]
    public let continueWatching: [ContinueItem]
    /// Watched titles, latest first; those whose files are gone list none.
    public let watched: [CatalogTitle]

    enum CodingKeys: String, CodingKey {
        case titles
        case continueWatching = "continue"
        case watched
    }
}

public struct CatalogTitle: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: CatalogKind
    public let title: String
    public let year: Int?
    public let overview: String?
    public let tmdbId: Int?
    public let poster: Bool
    public let backdrop: Bool
    public let logo: Bool
    public let runtime: Int?
    public let certification: String?
    public let genres: [String]
    public let crew: [CatalogCrewMember]
    public let matched: MatchSource?
    public let cast: [CatalogCastMember]
    public let added: Int
    /// When every movie file or episode was finished; nil while any is not.
    public let watched: Int?
    public let files: [CatalogFile]
}

public struct CatalogCrewMember: Codable, Equatable, Sendable {
    public let personId: Int
    public let name: String
    public let job: String
    public let profile: Bool
}

public struct CatalogCastMember: Codable, Equatable, Sendable {
    public let personId: Int
    public let name: String
    public let character: String
    public let profile: Bool
}

public enum CatalogKind: String, Codable, Equatable, Sendable {
    case movie, show
}

public enum MatchSource: String, Codable, Equatable, Sendable {
    case auto, manual
}

public struct MatchCandidate: Codable, Equatable, Identifiable, Sendable {
    public let tmdbId: Int
    public let title: String
    public let year: Int?
    public let overview: String?
    public let poster: Bool

    public var id: Int { tmdbId }
}

public struct CatalogFile: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let name: String
    public let size: Int64
    public let season: Int?
    public let episode: Int?
    public let episodeTitle: String?
    public let episodeOverview: String?
    public let airDate: String?
    public let runtime: Int?
    public let still: Bool
    public let media: CatalogMedia?
    public let subtitles: [CatalogSubtitle]
    public let progress: PlaybackProgress?

    public var id: String { path }
}

public struct CatalogMedia: Codable, Equatable, Sendable {
    public struct Video: Codable, Equatable, Sendable {
        public let codec: String
        public let width: Int
        public let height: Int
        public let bitDepth: Int
        public let hdr: HDRFormat?
    }

    public struct Audio: Codable, Equatable, Sendable {
        public let codec: String
        public let channels: Int
        public let language: String?
        public let title: String?
        public let atmos: Bool
        public let `default`: Bool
    }

    public struct Subtitle: Codable, Equatable, Sendable {
        public let codec: String
        public let language: String?
        public let title: String?
        public let forced: Bool
    }

    public let duration: Double
    public let video: Video
    public let audio: [Audio]
    public let subtitles: [Subtitle]
}

public enum HDRFormat: String, Codable, Equatable, Sendable {
    case dolbyVision, hdr10plus, hdr10, hlg
}

public struct CatalogSubtitle: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let name: String
    public let label: String

    public var id: String { path }
}

public struct PlaybackProgress: Codable, Equatable, Sendable {
    public let path: String?
    public let position: Double
    public let duration: Double
    public let finished: Bool
    public let updated: Int
}

/// The subtitle picked for a file: off, a catalog sidecar (its own file finds it by `name`, the title's
/// other files by `label`), or an embedded stream by its container stream index.
public enum SubtitleChoice: Codable, Equatable, Sendable {
    case off
    case sidecar(label: String, name: String?)
    case stream(index: Int, language: String?)

    private enum CodingKeys: String, CodingKey { case kind, label, name, index, language }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "off":
            self = .off
        case "sidecar":
            self = .sidecar(label: try container.decode(String.self, forKey: .label),
                            name: try container.decodeIfPresent(String.self, forKey: .name))
        case "stream":
            self = .stream(index: try container.decode(Int.self, forKey: .index),
                           language: try container.decodeIfPresent(String.self, forKey: .language))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown subtitle kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .off:
            try container.encode("off", forKey: .kind)
        case .sidecar(let label, let name):
            try container.encode("sidecar", forKey: .kind)
            try container.encode(label, forKey: .label)
            try container.encodeIfPresent(name, forKey: .name)
        case .stream(let index, let language):
            try container.encode("stream", forKey: .kind)
            try container.encode(index, forKey: .index)
            try container.encodeIfPresent(language, forKey: .language)
        }
    }
}

public struct SubtitleChoiceRecord: Codable, Equatable, Sendable {
    public let path: String
    /// nil when neither the file nor another file of its title has a choice.
    public let subtitle: SubtitleChoice?
}

public struct ContinueItem: Codable, Equatable, Sendable {
    public let titleId: String
    public let path: String
}

public enum ArtKind: Equatable, Sendable {
    case poster, backdrop, logo
    case profile(personID: Int)
    case still(season: Int, episode: Int)
}

public struct UploadResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let filename: String
}

public struct SubtitleUploadResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let filename: String
    public let activated: Bool
}

public struct SystemInfo: Codable, Equatable, Sendable {
    public struct CPU: Codable, Equatable, Sendable {
        public let percent: Double
        public let temp: Double?
    }

    public struct Memory: Codable, Equatable, Sendable {
        public let total: Int64
        public let used: Int64
        public let free: Int64
        public let percent: Double
    }

    public struct Network: Codable, Equatable, Sendable {
        public let downloadSpeed: Int64
        public let uploadSpeed: Int64

        enum CodingKeys: String, CodingKey {
            case downloadSpeed = "download_speed"
            case uploadSpeed = "upload_speed"
        }
    }

    public let cpu: CPU
    public let memory: Memory
    public let network: Network
    public let uptime: Int
}

public struct PlayerState: Codable, Equatable, Sendable {
    public let active: Bool
    public let playerID: Int?
    public let title: String?
    public let file: String?
    public let percentage: Double
    public let time: Double
    public let totalTime: Double
    public let speed: Double
    public let volume: Int?
    public let muted: Bool?
    public let audioStreams: [MediaStream]
    public let currentAudioStream: MediaStream?
    public let videoStreams: [MediaStream]
    public let currentVideoStream: MediaStream?
    public let subtitles: [MediaStream]
    public let currentSubtitle: MediaStream?
    public let subtitleEnabled: Bool

    public var currentAudioIndex: Int? { currentAudioStream?.index }
    public var currentVideoIndex: Int? { currentVideoStream?.index }
    public var currentSubtitleIndex: Int? { currentSubtitle?.index }

    enum CodingKeys: String, CodingKey {
        case active, title, file, percentage, time, speed, volume, muted, subtitles
        case playerID = "playerid"
        case totalTime = "totaltime"
        case audioStreams = "audiostreams"
        case currentAudioStream = "currentaudiostream"
        case videoStreams = "videostreams"
        case currentVideoStream = "currentvideostream"
        case currentSubtitle = "currentsubtitle"
        case subtitleEnabled = "subtitleenabled"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        active = try values.decode(Bool.self, forKey: .active)
        playerID = try values.decodeIfPresent(Int.self, forKey: .playerID)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        file = try values.decodeIfPresent(String.self, forKey: .file)
        percentage = try values.decodeIfPresent(Double.self, forKey: .percentage) ?? 0
        time = try values.decodeIfPresent(Double.self, forKey: .time) ?? 0
        totalTime = try values.decodeIfPresent(Double.self, forKey: .totalTime) ?? 0
        speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        volume = try values.decodeIfPresent(Int.self, forKey: .volume)
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted)
        audioStreams = try values.decodeIfPresent([MediaStream].self, forKey: .audioStreams) ?? []
        videoStreams = try values.decodeIfPresent([MediaStream].self, forKey: .videoStreams) ?? []
        subtitles = try values.decodeIfPresent([MediaStream].self, forKey: .subtitles) ?? []
        currentAudioStream = try Self.current(values, key: .currentAudioStream)
        currentVideoStream = try Self.current(values, key: .currentVideoStream)
        currentSubtitle = try Self.current(values, key: .currentSubtitle)
        subtitleEnabled = try values.decodeIfPresent(Bool.self, forKey: .subtitleEnabled) ?? false
    }

    private static func current(_ values: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> MediaStream? {
        let stream = try values.decodeIfPresent(MediaStream.self, forKey: key)
        return stream?.index == nil ? nil : stream
    }
}

public struct MediaStream: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let index: Int?
    public let name: String?
    public let language: String?
    public let codec: String?
    public let type: String?
    public let width: Int?
    public let height: Int?
    public let channels: Int?

    public var id: Int? { index }
}

public enum DelayDirection: String, Codable, Sendable {
    case minus, plus
}

public enum StreamQuality: String, CaseIterable, Codable, Sendable {
    case compatible
    case p720 = "720p"
    case p1080 = "1080p"
}

public enum SubtitleSelection: Encodable, Equatable, Sendable {
    case index(Int)
    case off
    case on
    case next
    case previous

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .index(let index): try value.encode(index)
        case .off: try value.encode("off")
        case .on: try value.encode("on")
        case .next: try value.encode("next")
        case .previous: try value.encode("previous")
        }
    }
}

public struct StreamResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let title: String
    public let source: String
    public let quality: String
}
