//
//  InterlaceAPI.swift
//  Interlace-Remote
//

import Foundation
import Network

struct InterlaceAPI: Sendable {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    static func normalizedBaseURL(from text: String) throws -> URL {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw InterlaceAPIError.invalidBaseURL("Enter an Interlace server URL.")
        }

        if !candidate.contains("://") {
            candidate = "http://\(candidate)"
        }

        guard var components = URLComponents(string: candidate) else {
            throw InterlaceAPIError.invalidBaseURL("The server URL is not valid.")
        }

        components.query = nil
        components.fragment = nil

        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw InterlaceAPIError.invalidBaseURL("Use an http:// or https:// server URL.")
        }

        components.scheme = scheme

        guard components.host?.isEmpty == false else {
            throw InterlaceAPIError.invalidBaseURL("The server URL needs a host name or IP address.")
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
            throw InterlaceAPIError.invalidBaseURL("The server URL could not be normalized.")
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

    func status() async throws -> StatusResponse {
        try await get("/api/status")
    }

    func capabilities() async throws -> CapabilitiesResponse {
        try await get("/api/capabilities")
    }

    func downloads() async throws -> [DownloadItem] {
        let data = try await requestData(method: "GET", path: "/api/downloads")
        if let items = try? Self.decoder.decode([DownloadItem].self, from: data) {
            return items
        }
        return try Self.decoder.decode(DownloadsResponse.self, from: data).items
    }

    func addDownload(uri: String) async throws {
        try await postVoid("/api/downloads", body: URIRequest(uri: uri))
    }

    func uploadTorrent(fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent.isEmpty ? "upload.torrent" : fileURL.lastPathComponent
        try await uploadTorrent(fileName: fileName, data: data)
    }

    func uploadTorrent(fileName: String, data: Data) async throws {
        try await multipartPost(
            path: "/api/downloads/torrent",
            files: [
                MultipartFile(
                    fieldName: "file",
                    fileName: fileName,
                    contentType: "application/x-bittorrent",
                    data: data
                )
            ]
        )
    }

    func upload(fileURL: URL, to path: String?) async throws {
        let data = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent.isEmpty ? "upload" : fileURL.lastPathComponent
        try await upload(fileName: fileName, data: data, to: path)
    }

    func upload(fileName: String, data: Data, to path: String?) async throws {
        var fields: [String: String] = [:]
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedPath.isEmpty {
            fields["path"] = trimmedPath
        }

        try await multipartPost(
            path: "/api/upload",
            fields: fields,
            files: [
                MultipartFile(
                    fieldName: "file",
                    fileName: fileName,
                    contentType: "application/octet-stream",
                    data: data
                )
            ]
        )
    }

    func uploadSubtitle(videoPath: String, fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent.isEmpty ? "subtitle" : fileURL.lastPathComponent
        try await uploadSubtitle(videoPath: videoPath, fileName: fileName, data: data)
    }

    func uploadSubtitle(videoPath: String, fileName: String, data: Data) async throws {
        try await multipartPost(
            path: "/api/upload/subtitle",
            fields: ["video_path": videoPath],
            files: [
                MultipartFile(
                    fieldName: "file",
                    fileName: fileName,
                    contentType: "text/plain",
                    data: data
                )
            ]
        )
    }

    func pauseDownload(gid: String) async throws {
        try await postVoid("/api/downloads/\(Self.pathComponent(gid))/pause")
    }

    func resumeDownload(gid: String) async throws {
        try await postVoid("/api/downloads/\(Self.pathComponent(gid))/resume")
    }

    func removeDownload(gid: String) async throws {
        try await deleteVoid("/api/downloads/\(Self.pathComponent(gid))")
    }

    func library(path: String? = nil) async throws -> LibraryResponse {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let queryItems = trimmedPath.isEmpty ? nil : [URLQueryItem(name: "path", value: trimmedPath)]
        return try await get("/api/library", queryItems: queryItems)
    }

    func deleteLibraryItem(path: String) async throws {
        try await deleteVoid("/api/library", body: PathRequest(path: path))
    }

    func play(path: String) async throws {
        try await postVoid("/api/play", body: PathRequest(path: path))
    }

    func player() async throws -> PlayerState {
        try await get("/api/player")
    }

    func playPause() async throws {
        try await postVoid("/api/player/playpause")
    }

    func stop() async throws {
        try await postVoid("/api/player/stop")
    }

    func seek(percentage: Double) async throws {
        try await postVoid("/api/player/seek", body: SeekRequest(percentage: percentage.clamped(to: 0...100)))
    }

    func setVolume(level: Int) async throws {
        try await postVoid("/api/player/volume", body: VolumeRequest(level: level.clamped(to: 0...100)))
    }

    func setMute(_ muted: Bool) async throws {
        try await postVoid("/api/player/mute", body: MuteRequest(muted: muted))
    }

    func setAudio(index: Int) async throws {
        try await postVoid("/api/player/audio", body: StreamIndexRequest(index: index))
    }

    func setVideo(index: Int) async throws {
        try await postVoid("/api/player/video", body: StreamIndexRequest(index: index))
    }

    func setSubtitle(index: Int) async throws {
        try await postVoid("/api/player/subtitle", body: SubtitleIndexRequest(value: index))
    }

    func setSubtitleOff() async throws {
        try await postVoid("/api/player/subtitle", body: SubtitleOffRequest(value: "off"))
    }

    func subtitleDelay(_ direction: DelayDirection) async throws {
        try await postVoid("/api/player/subtitle-delay", body: DelayRequest(direction: direction.rawValue))
    }

    func audioDelay(_ direction: DelayDirection) async throws {
        try await postVoid("/api/player/audio-delay", body: DelayRequest(direction: direction.rawValue))
    }

    func systemStats() async throws -> SystemInfo {
        try await get("/api/system")
    }
}

private extension InterlaceAPI {
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: configuration)
    }()

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]? = nil) async throws -> T {
        let data = try await requestData(method: "GET", path: path, queryItems: queryItems)
        return try Self.decoder.decode(T.self, from: data)
    }

    func postVoid(_ path: String) async throws {
        _ = try await requestData(method: "POST", path: path)
    }

    func postVoid<Body: Encodable>(_ path: String, body: Body) async throws {
        let data = try Self.encoder.encode(body)
        _ = try await requestData(method: "POST", path: path, body: data)
    }

    func deleteVoid(_ path: String) async throws {
        _ = try await requestData(method: "DELETE", path: path)
    }

    func deleteVoid<Body: Encodable>(_ path: String, body: Body) async throws {
        let data = try Self.encoder.encode(body)
        _ = try await requestData(method: "DELETE", path: path, body: data)
    }

    func requestData(
        method: String,
        path: String,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> Data {
        let url = url(for: path, queryItems: queryItems)
        if url.scheme?.lowercased() == "http" {
            return try await requestPlainHTTPData(
                method: method,
                url: url,
                body: body,
                contentType: contentType
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await Self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw InterlaceAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw InterlaceAPIError.httpStatus(httpResponse.statusCode, responseText)
        }

        return data
    }

    func multipartPost(
        path: String,
        fields: [String: String] = [:],
        files: [MultipartFile]
    ) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = Self.multipartBody(boundary: boundary, fields: fields, files: files)
        _ = try await requestData(
            method: "POST",
            path: path,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    func requestPlainHTTPData(
        method: String,
        url: URL,
        body: Data?,
        contentType: String
    ) async throws -> Data {
        guard let host = url.host else {
            throw InterlaceAPIError.invalidBaseURL("The server URL needs a host name or IP address.")
        }

        let port = url.port ?? 80
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw InterlaceAPIError.invalidBaseURL("The server port is not valid.")
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let request = Self.plainHTTPRequest(method: method, url: url, body: body, contentType: contentType)

        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = PlainHTTPConnectionState(continuation: continuation, connection: connection)
                let queue = DispatchQueue(label: "InterlaceRemote.PlainHTTP.\(UUID().uuidString)")

                connection.stateUpdateHandler = { nwState in
                    switch nwState {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { error in
                            if let error {
                                state.resume(throwing: error)
                            } else {
                                Self.receivePlainHTTPResponse(on: connection, state: state)
                            }
                        })
                    case .failed(let error):
                        state.resume(throwing: error)
                    case .cancelled:
                        state.resume(throwing: URLError(.cancelled))
                    default:
                        break
                    }
                }

                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }

        let parsed = try Self.parsePlainHTTPResponse(responseData)
        guard (200..<300).contains(parsed.statusCode) else {
            let responseText = String(data: parsed.body, encoding: .utf8) ?? ""
            throw InterlaceAPIError.httpStatus(parsed.statusCode, responseText)
        }

        return parsed.body
    }

    func url(for path: String, queryItems: [URLQueryItem]? = nil) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/\(endpoint)" : "/\(basePath)/\(endpoint)"
        components.queryItems = queryItems?.isEmpty == false ? queryItems : nil
        components.fragment = nil
        return components.url!
    }

    static func multipartBody(boundary: String, fields: [String: String], files: [MultipartFile]) -> Data {
        var body = Data()

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.appendMultipart("--\(boundary)\r\n")
            body.appendMultipart("Content-Disposition: form-data; name=\"\(escapeMultipart(name))\"\r\n\r\n")
            body.appendMultipart(value)
            body.appendMultipart("\r\n")
        }

        for file in files {
            body.appendMultipart("--\(boundary)\r\n")
            body.appendMultipart("Content-Disposition: form-data; name=\"\(escapeMultipart(file.fieldName))\"; filename=\"\(escapeMultipart(file.fileName))\"\r\n")
            body.appendMultipart("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            body.appendMultipart("\r\n")
        }

        body.appendMultipart("--\(boundary)--\r\n")
        return body
    }

    static func escapeMultipart(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func plainHTTPRequest(method: String, url: URL, body: Data?, contentType: String) -> Data {
        let path = url.path.isEmpty ? "/" : url.path
        let target = url.query.map { "\(path)?\($0)" } ?? path
        let port = url.port ?? 80
        let host = url.host ?? ""
        let hostName = host.contains(":") ? "[\(host)]" : host
        let hostHeader = port == 80 ? hostName : "\(hostName):\(port)"

        var headerLines = [
            "\(method) \(target) HTTP/1.1",
            "Host: \(hostHeader)",
            "Accept: application/json",
            "Connection: close"
        ]

        if let body {
            headerLines.append("Content-Type: \(contentType)")
            headerLines.append("Content-Length: \(body.count)")
        }

        var request = Data(headerLines.joined(separator: "\r\n").utf8)
        request.appendMultipart("\r\n\r\n")
        if let body {
            request.append(body)
        }
        return request
    }

    static func receivePlainHTTPResponse(on connection: NWConnection, state: PlainHTTPConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let error {
                state.resume(throwing: error)
                return
            }

            if let data, !data.isEmpty {
                state.append(data)
            }

            if isComplete {
                state.resumeReturningReceivedData()
            } else {
                receivePlainHTTPResponse(on: connection, state: state)
            }
        }
    }

    static func parsePlainHTTPResponse(_ data: Data) throws -> (statusCode: Int, body: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            throw InterlaceAPIError.invalidResponse
        }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw InterlaceAPIError.invalidResponse
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard
            let statusLine = lines.first,
            let statusCodeText = statusLine.split(separator: " ").dropFirst().first,
            let statusCode = Int(statusCodeText)
        else {
            throw InterlaceAPIError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let rawBody = data.subdata(in: headerRange.upperBound..<data.endIndex)
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunkedBody(rawBody)
        } else if let contentLengthText = headers["content-length"], let contentLength = Int(contentLengthText) {
            body = rawBody.prefixData(contentLength)
        } else {
            body = rawBody
        }

        return (statusCode, body)
    }

    static func decodeChunkedBody(_ data: Data) throws -> Data {
        let lineBreak = Data("\r\n".utf8)
        var index = data.startIndex
        var decoded = Data()

        while index < data.endIndex {
            guard let lineRange = data[index..<data.endIndex].range(of: lineBreak) else {
                throw InterlaceAPIError.invalidResponse
            }

            let sizeLineData = data.subdata(in: index..<lineRange.lowerBound)
            guard
                let sizeLine = String(data: sizeLineData, encoding: .ascii),
                let sizeText = sizeLine.split(separator: ";").first,
                let chunkSize = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16)
            else {
                throw InterlaceAPIError.invalidResponse
            }

            index = lineRange.upperBound
            if chunkSize == 0 {
                return decoded
            }

            let chunkEnd = index + chunkSize
            guard chunkEnd <= data.endIndex else {
                throw InterlaceAPIError.invalidResponse
            }

            decoded.append(data.subdata(in: index..<chunkEnd))
            index = chunkEnd

            if index < data.endIndex {
                guard data[index..<data.endIndex].starts(with: lineBreak) else {
                    throw InterlaceAPIError.invalidResponse
                }
                index += lineBreak.count
            }
        }

        return decoded
    }
}

private nonisolated final class PlainHTTPConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var receivedData = Data()
    private let continuation: CheckedContinuation<Data, Error>
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Data, Error>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func append(_ data: Data) {
        lock.lock()
        receivedData.append(data)
        lock.unlock()
    }

    func resumeReturningReceivedData() {
        lock.lock()
        let data = receivedData
        lock.unlock()
        resume(returning: data)
    }

    func resume(returning data: Data) {
        complete {
            continuation.resume(returning: data)
        }
    }

    func resume(throwing error: Error) {
        complete {
            continuation.resume(throwing: error)
        }
    }

    private func complete(_ resume: () -> Void) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        connection.cancel()
        resume()
    }
}

enum InterlaceAPIError: LocalizedError, Sendable {
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

struct StatusResponse: Decodable, Equatable, Sendable {
    let ok: Bool?
    let status: String?
    let message: String?
    let version: String?

    var summary: String {
        if let status, !status.isEmpty {
            return status
        }
        if ok == true {
            return "online"
        }
        return "connected"
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if let string = try? single.decode(String.self) {
                ok = nil
                status = string
                message = nil
                version = nil
                return
            }

            if let bool = try? single.decode(Bool.self) {
                ok = bool
                status = nil
                message = nil
                version = nil
                return
            }
        }

        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        ok = container.decodeFlexibleBoolIfPresent(forKey: "ok")
            ?? container.decodeFlexibleBoolIfPresent(forKey: "healthy")
        status = container.decodeFlexibleStringIfPresent(forKey: "status")
            ?? container.decodeFlexibleStringIfPresent(forKey: "state")
        message = container.decodeFlexibleStringIfPresent(forKey: "message")
        version = container.decodeFlexibleStringIfPresent(forKey: "version")
    }
}

struct CapabilitiesResponse: Decodable, Equatable, Sendable {
    let values: [String: Bool]

    var enabledNames: [String] {
        values
            .filter { $0.value }
            .map(\.key)
            .sorted()
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self) else {
            values = [:]
            return
        }

        var decoded: [String: Bool] = [:]
        for key in container.allKeys {
            if let bool = container.decodeFlexibleBoolIfPresent(forKey: key) {
                decoded[key.stringValue] = bool
            }
        }

        values = decoded
    }
}

struct DownloadItem: Decodable, Identifiable, Equatable, Sendable {
    let gid: String
    let name: String
    let status: String
    let total: Int64
    let completed: Int64
    let progress: Double
    let speed: Int64
    let isTorrent: Bool
    let error: String?

    var id: String { gid }

    enum CodingKeys: String, CodingKey {
        case gid
        case name
        case status
        case total
        case completed
        case progress
        case speed
        case isTorrent = "is_torrent"
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gid = container.decodeFlexibleStringIfPresent(forKey: .gid) ?? UUID().uuidString
        name = container.decodeFlexibleStringIfPresent(forKey: .name) ?? gid
        status = container.decodeFlexibleStringIfPresent(forKey: .status) ?? "unknown"
        total = container.decodeFlexibleInt64IfPresent(forKey: .total) ?? 0
        completed = container.decodeFlexibleInt64IfPresent(forKey: .completed) ?? 0
        speed = container.decodeFlexibleInt64IfPresent(forKey: .speed) ?? 0
        isTorrent = container.decodeFlexibleBoolIfPresent(forKey: .isTorrent) ?? false
        error = container.decodeFlexibleStringIfPresent(forKey: .error)

        if let decodedProgress = container.decodeFlexibleDoubleIfPresent(forKey: .progress) {
            progress = decodedProgress
        } else if total > 0 {
            progress = (Double(completed) / Double(total)) * 100
        } else {
            progress = 0
        }
    }
}

struct LibraryResponse: Decodable, Equatable, Sendable {
    let items: [LibraryItem]
    let disk: DiskInfo?

    enum CodingKeys: String, CodingKey {
        case items
        case disk
    }

    init(from decoder: Decoder) throws {
        if let items = try? [LibraryItem](from: decoder) {
            self.items = items
            disk = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decode([LibraryItem].self, forKey: .items)) ?? []
        disk = try? container.decode(DiskInfo.self, forKey: .disk)
    }
}

struct LibraryItem: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let rel: String
    let size: Int64
    let type: LibraryItemType

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
        type = (try? container.decode(LibraryItemType.self, forKey: .type)) ?? .file
    }
}

enum LibraryItemType: String, Decodable, Equatable, Sendable {
    case file
    case directory
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = (try? container.decode(String.self))?.lowercased() ?? ""
        self = LibraryItemType(rawValue: value) ?? .unknown
    }
}

struct DiskInfo: Decodable, Equatable, Sendable {
    let total: Int64
    let used: Int64
    let free: Int64
    let percent: Double

    enum CodingKeys: String, CodingKey {
        case total
        case used
        case free
        case percent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.decodeFlexibleInt64IfPresent(forKey: .total) ?? 0
        used = container.decodeFlexibleInt64IfPresent(forKey: .used) ?? 0
        free = container.decodeFlexibleInt64IfPresent(forKey: .free) ?? 0
        percent = container.decodeFlexibleDoubleIfPresent(forKey: .percent) ?? 0
    }
}

struct SystemInfo: Decodable, Equatable, Sendable {
    let cpuPercent: Double
    let cpuTemp: Double?
    let memTotal: Int64
    let memUsed: Int64
    let memFree: Int64
    let memPercent: Double
    let downloadSpeed: Int64
    let uploadSpeed: Int64
    let uptime: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)

        let cpu = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("cpu"))
        cpuPercent = cpu?.decodeFlexibleDoubleIfPresent(forKey: "percent") ?? 0
        cpuTemp = cpu?.decodeFlexibleDoubleIfPresent(forKey: "temp")

        let mem = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("memory"))
        memTotal = mem?.decodeFlexibleInt64IfPresent(forKey: "total") ?? 0
        memUsed = mem?.decodeFlexibleInt64IfPresent(forKey: "used") ?? 0
        memFree = mem?.decodeFlexibleInt64IfPresent(forKey: "free") ?? 0
        memPercent = mem?.decodeFlexibleDoubleIfPresent(forKey: "percent") ?? 0

        let net = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("network"))
        downloadSpeed = net?.decodeFlexibleInt64IfPresent(forKey: "download_speed") ?? 0
        uploadSpeed = net?.decodeFlexibleInt64IfPresent(forKey: "upload_speed") ?? 0

        uptime = container.decodeFlexibleIntIfPresent(forKey: "uptime") ?? 0
    }
}

struct PlayerState: Decodable, Equatable, Sendable {
    let active: Bool
    let title: String?
    let file: String?
    let percentage: Double
    let time: Double
    let totalTime: Double
    let speed: Double
    let volume: Int
    let muted: Bool
    let audioStreams: [MediaStream]
    let currentAudioStream: MediaStream?
    let videoStreams: [MediaStream]
    let currentVideoStream: MediaStream?
    let subtitles: [MediaStream]
    let currentSubtitle: MediaStream?
    let subtitleEnabled: Bool

    var currentAudioIndex: Int? {
        currentAudioStream?.index
    }

    var currentVideoIndex: Int? {
        currentVideoStream?.index
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
        case videoStreams = "videostreams"
        case currentVideoStream = "currentvideostream"
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
        volume = Int(container.decodeFlexibleDoubleIfPresent(forKey: .volume) ?? 0).clamped(to: 0...100)
        muted = container.decodeFlexibleBoolIfPresent(forKey: .muted) ?? false
        audioStreams = (try? container.decode([MediaStream].self, forKey: .audioStreams)) ?? []
        currentAudioStream = try? container.decode(MediaStream.self, forKey: .currentAudioStream)
        videoStreams = (try? container.decode([MediaStream].self, forKey: .videoStreams)) ?? []
        currentVideoStream = try? container.decode(MediaStream.self, forKey: .currentVideoStream)
        subtitles = (try? container.decode([MediaStream].self, forKey: .subtitles)) ?? []
        currentSubtitle = try? container.decode(MediaStream.self, forKey: .currentSubtitle)
        subtitleEnabled = container.decodeFlexibleBoolIfPresent(forKey: .subtitleEnabled) ?? false
    }
}

struct MediaStream: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let index: Int?
    let name: String?
    let language: String?
    let codec: String?
    let type: String?
    let width: Int?
    let height: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        index = container.decodeFlexibleIntIfPresent(forKey: "index")
        let decodedID = container.decodeFlexibleStringIfPresent(forKey: "id")
            ?? index.map(String.init)
        name = container.decodeFlexibleStringIfPresent(forKey: "name")
            ?? container.decodeFlexibleStringIfPresent(forKey: "title")
        language = container.decodeFlexibleStringIfPresent(forKey: "language")
            ?? container.decodeFlexibleStringIfPresent(forKey: "lang")
        codec = container.decodeFlexibleStringIfPresent(forKey: "codec")
        type = container.decodeFlexibleStringIfPresent(forKey: "type")
        width = container.decodeFlexibleIntIfPresent(forKey: "width")
        height = container.decodeFlexibleIntIfPresent(forKey: "height")
        let fallbackID = [type, language, codec, name].compactMap { $0 }.joined(separator: ":")
        id = decodedID ?? (fallbackID.isEmpty ? "unknown" : fallbackID)
    }
}

enum DelayDirection: String, Sendable {
    case minus
    case plus
}

private struct MultipartFile {
    let fieldName: String
    let fileName: String
    let contentType: String
    let data: Data
}

private struct DownloadsResponse: Decodable {
    let items: [DownloadItem]

    enum CodingKeys: String, CodingKey {
        case items
        case downloads
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decode([DownloadItem].self, forKey: .items))
            ?? (try? container.decode([DownloadItem].self, forKey: .downloads))
            ?? []
    }
}

private struct URIRequest: Encodable {
    let uri: String
}

private struct PathRequest: Encodable {
    let path: String
}

private struct SeekRequest: Encodable {
    let percentage: Double
}

private struct VolumeRequest: Encodable {
    let level: Int
}

private struct MuteRequest: Encodable {
    let muted: Bool
}

private struct StreamIndexRequest: Encodable {
    let index: Int
}

private struct SubtitleIndexRequest: Encodable {
    let value: Int
}

private struct SubtitleOffRequest: Encodable {
    let value: String
}

private struct DelayRequest: Encodable {
    let direction: String
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
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

private extension KeyedDecodingContainer where Key == AnyCodingKey {
    func decodeFlexibleStringIfPresent(forKey key: String) -> String? {
        decodeFlexibleStringIfPresent(forKey: AnyCodingKey(key))
    }

    func decodeFlexibleIntIfPresent(forKey key: String) -> Int? {
        decodeFlexibleIntIfPresent(forKey: AnyCodingKey(key))
    }

    func decodeFlexibleInt64IfPresent(forKey key: String) -> Int64? {
        decodeFlexibleInt64IfPresent(forKey: AnyCodingKey(key))
    }

    func decodeFlexibleDoubleIfPresent(forKey key: String) -> Double? {
        decodeFlexibleDoubleIfPresent(forKey: AnyCodingKey(key))
    }

    func decodeFlexibleBoolIfPresent(forKey key: String) -> Bool? {
        decodeFlexibleBoolIfPresent(forKey: AnyCodingKey(key))
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

private extension Data {
    mutating func appendMultipart(_ string: String) {
        append(Data(string.utf8))
    }

    func prefixData(_ count: Int) -> Data {
        guard count < self.count else { return self }
        return subdata(in: startIndex..<(startIndex + count))
    }
}
