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
