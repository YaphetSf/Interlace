import Foundation

struct WatchInterlaceAPI: Sendable {
    /// The path that carries this request to the server — either a direct socket
    /// or a relay through the paired iPhone. See `WatchTransport`.
    let transport: any WatchTransport

    init(transport: any WatchTransport) {
        self.transport = transport
    }

    static func normalizedBaseURL(from text: String) throws -> URL {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw WatchInterlaceAPIError.invalidBaseURL("Enter an Interlace server URL.")
        }

        if !candidate.contains("://") {
            candidate = "http://\(candidate)"
        }

        guard var components = URLComponents(string: candidate) else {
            throw WatchInterlaceAPIError.invalidBaseURL("The server URL is not valid.")
        }

        components.query = nil
        components.fragment = nil

        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw WatchInterlaceAPIError.invalidBaseURL("Use an http:// or https:// server URL.")
        }

        components.scheme = scheme

        guard components.host?.isEmpty == false else {
            throw WatchInterlaceAPIError.invalidBaseURL("The server URL needs a host name or IP address.")
        }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        if path == "/api" {
            path = ""
        } else if path.hasSuffix("/api") {
            path.removeLast(4)
        }

        components.path = path == "/" ? "" : path

        guard let url = components.url else {
            throw WatchInterlaceAPIError.invalidBaseURL("The server URL could not be normalized.")
        }

        return url
    }

    static func displayString(for url: URL) -> String {
        var text = url.absoluteString
        if text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    func status() async throws {
        _ = try await requestData(method: "GET", path: "/api/status")
    }

    func library(path: String? = nil) async throws -> WatchLibraryResponse {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let queryItems = trimmedPath.isEmpty ? nil : [URLQueryItem(name: "path", value: trimmedPath)]
        let data = try await requestData(method: "GET", path: "/api/library", queryItems: queryItems)
        return try Self.decoder.decode(WatchLibraryResponse.self, from: data)
    }

    func play(path: String) async throws {
        let data = try Self.encoder.encode(WatchPathRequest(path: path))
        _ = try await requestData(method: "POST", path: "/api/play", body: data)
    }

    func player() async throws -> WatchPlayerState {
        let data = try await requestData(method: "GET", path: "/api/player")
        return try Self.decoder.decode(WatchPlayerState.self, from: data)
    }

    func playPause() async throws {
        _ = try await requestData(method: "POST", path: "/api/player/playpause")
    }

    func stop() async throws {
        _ = try await requestData(method: "POST", path: "/api/player/stop")
    }

    func seek(percentage: Double) async throws {
        let clamped = min(max(percentage, 0), 100)
        let data = try Self.encoder.encode(WatchSeekRequest(percentage: clamped))
        _ = try await requestData(method: "POST", path: "/api/player/seek", body: data)
    }

    func skip(seconds: Int) async throws {
        let data = try Self.encoder.encode(WatchSkipRequest(seconds: seconds))
        _ = try await requestData(method: "POST", path: "/api/player/skip", body: data)
    }

    func setVolume(level: Int) async throws {
        let clamped = min(max(level, 0), 100)
        let data = try Self.encoder.encode(WatchVolumeRequest(level: clamped))
        _ = try await requestData(method: "POST", path: "/api/player/volume", body: data)
    }

    func setMute(_ muted: Bool) async throws {
        let data = try Self.encoder.encode(WatchMuteRequest(muted: muted))
        _ = try await requestData(method: "POST", path: "/api/player/mute", body: data)
    }

    func setAudio(index: Int) async throws {
        let data = try Self.encoder.encode(WatchStreamIndexRequest(index: index))
        _ = try await requestData(method: "POST", path: "/api/player/audio", body: data)
    }

    func setSubtitle(index: Int) async throws {
        let data = try Self.encoder.encode(WatchSubtitleIndexRequest(value: index))
        _ = try await requestData(method: "POST", path: "/api/player/subtitle", body: data)
    }

    func setSubtitleOff() async throws {
        let data = try Self.encoder.encode(WatchSubtitleOffRequest(value: "off"))
        _ = try await requestData(method: "POST", path: "/api/player/subtitle", body: data)
    }
}

private extension WatchInterlaceAPI {
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()
    func requestData(
        method: String,
        path: String,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> Data {
        let (status, data) = try await transport.send(
            method: method,
            path: path,
            queryItems: queryItems,
            body: body,
            contentType: contentType
        )

        guard (200..<300).contains(status) else {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw WatchInterlaceAPIError.httpStatus(status, responseText)
        }

        return data
    }
}

enum WatchInterlaceAPIError: LocalizedError, Sendable {
    case invalidBaseURL(String)
    case invalidResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let message):
            return message
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpStatus(let statusCode, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "The server returned HTTP \(statusCode)."
            }
            return "The server returned HTTP \(statusCode): \(detail.prefix(240))"
        }
    }
}

struct WatchLibraryResponse: Decodable, Equatable, Sendable {
    let items: [WatchLibraryItem]

    enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        if let items = try? [WatchLibraryItem](from: decoder) {
            self.items = items
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decode([WatchLibraryItem].self, forKey: .items)) ?? []
    }
}

struct WatchLibraryItem: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let rel: String
    let size: Int64
    let type: WatchLibraryItemType

    var isDirectory: Bool {
        type == .directory
    }

    var id: String {
        if !path.isEmpty {
            return path
        }
        if !rel.isEmpty {
            return rel
        }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case rel
        case size
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = container.decodeFlexibleStringIfPresent(forKey: .path) ?? ""
        rel = container.decodeFlexibleStringIfPresent(forKey: .rel) ?? ""
        let fallbackName = rel.split(separator: "/").last.map(String.init)
            ?? path.split(separator: "/").last.map(String.init)
            ?? "Untitled"
        name = container.decodeFlexibleStringIfPresent(forKey: .name) ?? fallbackName
        size = container.decodeFlexibleInt64IfPresent(forKey: .size) ?? 0
        type = (try? container.decode(WatchLibraryItemType.self, forKey: .type)) ?? .file
    }
}

enum WatchLibraryItemType: String, Decodable, Equatable, Sendable {
    case file
    case directory
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = (try? container.decode(String.self))?.lowercased() ?? ""
        self = WatchLibraryItemType(rawValue: value) ?? .unknown
    }
}

struct WatchPlayerState: Decodable, Equatable, Sendable {
    let active: Bool
    let title: String?
    let file: String?
    let percentage: Double
    let time: Double
    let totalTime: Double
    let speed: Double
    let volume: Int
    let muted: Bool
    let audioStreams: [WatchMediaStream]
    let currentAudioStream: WatchMediaStream?
    let subtitles: [WatchMediaStream]
    let currentSubtitle: WatchMediaStream?
    let subtitleEnabled: Bool

    var isPaused: Bool {
        speed == 0
    }

    var currentAudioIndex: Int? {
        currentAudioStream?.index
    }

    var currentSubtitleIndex: Int? {
        currentSubtitle?.index
    }

    enum CodingKeys: String, CodingKey {
        case active
        case title
        case file
        case percentage
        case time
        case totalTime = "totaltime"
        case speed
        case volume
        case muted
        case audioStreams = "audiostreams"
        case currentAudioStream = "currentaudiostream"
        case subtitles
        case currentSubtitle = "currentsubtitle"
        case subtitleEnabled = "subtitleenabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = container.decodeFlexibleBoolIfPresent(forKey: .active) ?? false
        title = container.decodeFlexibleStringIfPresent(forKey: .title)
        file = container.decodeFlexibleStringIfPresent(forKey: .file)
        percentage = container.decodeFlexibleDoubleIfPresent(forKey: .percentage) ?? 0
        time = container.decodeFlexibleDoubleIfPresent(forKey: .time) ?? 0
        totalTime = container.decodeFlexibleDoubleIfPresent(forKey: .totalTime) ?? 0
        speed = container.decodeFlexibleDoubleIfPresent(forKey: .speed) ?? 1
        let rawVolume = container.decodeFlexibleDoubleIfPresent(forKey: .volume) ?? 0
        volume = min(max(Int(rawVolume), 0), 100)
        muted = container.decodeFlexibleBoolIfPresent(forKey: .muted) ?? false
        audioStreams = (try? container.decode([WatchMediaStream].self, forKey: .audioStreams)) ?? []
        currentAudioStream = try? container.decode(WatchMediaStream.self, forKey: .currentAudioStream)
        subtitles = (try? container.decode([WatchMediaStream].self, forKey: .subtitles)) ?? []
        currentSubtitle = try? container.decode(WatchMediaStream.self, forKey: .currentSubtitle)
        subtitleEnabled = container.decodeFlexibleBoolIfPresent(forKey: .subtitleEnabled) ?? false
    }
}

extension WatchPlayerState {
    init(
        active: Bool,
        title: String?,
        file: String?,
        percentage: Double,
        time: Double,
        totalTime: Double,
        speed: Double,
        volume: Int,
        muted: Bool,
        audioStreams: [WatchMediaStream],
        currentAudioStream: WatchMediaStream?,
        subtitles: [WatchMediaStream],
        currentSubtitle: WatchMediaStream?,
        subtitleEnabled: Bool
    ) {
        self.active = active
        self.title = title
        self.file = file
        self.percentage = percentage
        self.time = time
        self.totalTime = totalTime
        self.speed = speed
        self.volume = volume
        self.muted = muted
        self.audioStreams = audioStreams
        self.currentAudioStream = currentAudioStream
        self.subtitles = subtitles
        self.currentSubtitle = currentSubtitle
        self.subtitleEnabled = subtitleEnabled
    }

    private func with(
        percentage: Double? = nil,
        time: Double? = nil,
        speed: Double? = nil,
        volume: Int? = nil,
        muted: Bool? = nil
    ) -> WatchPlayerState {
        WatchPlayerState(
            active: active,
            title: title,
            file: file,
            percentage: percentage ?? self.percentage,
            time: time ?? self.time,
            totalTime: totalTime,
            speed: speed ?? self.speed,
            volume: volume ?? self.volume,
            muted: muted ?? self.muted,
            audioStreams: audioStreams,
            currentAudioStream: currentAudioStream,
            subtitles: subtitles,
            currentSubtitle: currentSubtitle,
            subtitleEnabled: subtitleEnabled
        )
    }

    func togglingPlayback() -> WatchPlayerState {
        with(speed: isPaused ? 1 : 0)
    }

    func seeking(toPercentage percentage: Double) -> WatchPlayerState {
        let clamped = min(max(percentage, 0), 100)
        return with(percentage: clamped, time: totalTime * clamped / 100)
    }

    func settingVolume(_ level: Int) -> WatchPlayerState {
        with(volume: min(max(level, 0), 100))
    }

    func settingMuted(_ muted: Bool) -> WatchPlayerState {
        with(muted: muted)
    }
}

struct WatchMediaStream: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let index: Int?
    let name: String?
    let language: String?
    let codec: String?

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        if let language, !language.isEmpty {
            return language.uppercased()
        }
        if let codec, !codec.isEmpty {
            return codec.uppercased()
        }
        if let index {
            return "Track \(index)"
        }
        return "Track"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case index
        case name
        case title
        case language
        case lang
        case codec
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = container.decodeFlexibleIntIfPresent(forKey: .index)
        name = container.decodeFlexibleStringIfPresent(forKey: .name)
            ?? container.decodeFlexibleStringIfPresent(forKey: .title)
        language = container.decodeFlexibleStringIfPresent(forKey: .language)
            ?? container.decodeFlexibleStringIfPresent(forKey: .lang)
        codec = container.decodeFlexibleStringIfPresent(forKey: .codec)
        let decodedID = container.decodeFlexibleStringIfPresent(forKey: .id) ?? index.map(String.init)
        let fallbackID = [language, codec, name].compactMap { $0 }.joined(separator: ":")
        id = decodedID ?? (fallbackID.isEmpty ? "unknown" : fallbackID)
    }
}

private struct WatchPathRequest: Encodable {
    let path: String
}

private struct WatchSeekRequest: Encodable {
    let percentage: Double
}

private struct WatchSkipRequest: Encodable {
    let seconds: Int
}

private struct WatchVolumeRequest: Encodable {
    let level: Int
}

private struct WatchMuteRequest: Encodable {
    let muted: Bool
}

private struct WatchStreamIndexRequest: Encodable {
    let index: Int
}

private struct WatchSubtitleIndexRequest: Encodable {
    let value: Int
}

private struct WatchSubtitleOffRequest: Encodable {
    let value: String
}

private extension KeyedDecodingContainer {
    func decodeFlexibleStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func decodeFlexibleInt64IfPresent(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) -> Int? {
        if let value = decodeFlexibleInt64IfPresent(forKey: key) {
            return Int(value)
        }
        return nil
    }

    func decodeFlexibleDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    func decodeFlexibleBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "on":
                return true
            case "false", "no", "0", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
