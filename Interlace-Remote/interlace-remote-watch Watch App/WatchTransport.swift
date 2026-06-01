import Foundation
import Network
import WatchConnectivity

/// How a `WatchInterlaceAPI` request actually reaches the server.
///
/// There are two implementations:
/// - `WatchDirectTransport` opens a socket straight to the server (works when the
///   watch is on the same LAN / can route to the server itself).
/// - `WatchRelayTransport` forwards the request to the paired iPhone over
///   WatchConnectivity; the iPhone performs the HTTP call with *its* network
///   (so it inherits the phone's VPN / Tailscale route home) and sends the
///   response back.
///
/// `WatchInterlaceAPI` only knows about this protocol, so all the endpoint and
/// decoding logic is identical regardless of which path is in use.
protocol WatchTransport: Sendable {
    func send(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        body: Data?,
        contentType: String
    ) async throws -> (status: Int, body: Data)
}

// MARK: - Relay message contract

/// Shared dictionary keys for relayed requests/replies. The iPhone side
/// (`WatchRelayServer`) declares an identical set — keep them in sync.
enum RelayKey {
    static let method = "m"
    static let path = "p"
    static let query = "q"
    static let body = "b"
    static let contentType = "c"
    static let status = "s"
    static let responseBody = "d"
    static let error = "e"
}

// MARK: - Direct transport (watch talks to the server itself)

struct WatchDirectTransport: WatchTransport {
    let baseURL: URL

    func send(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        body: Data?,
        contentType: String
    ) async throws -> (status: Int, body: Data) {
        let url = url(for: path, queryItems: queryItems)
        if url.scheme?.lowercased() == "http" {
            return try await plainHTTPStatusAndBody(method: method, url: url, body: body, contentType: contentType)
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
            throw WatchInterlaceAPIError.invalidResponse
        }
        return (httpResponse.statusCode, data)
    }
}

private extension WatchDirectTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    func url(for path: String, queryItems: [URLQueryItem]? = nil) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/\(endpoint)" : "/\(basePath)/\(endpoint)"
        components.queryItems = queryItems?.isEmpty == false ? queryItems : nil
        components.fragment = nil
        return components.url!
    }

    // Plain HTTP over a raw socket, because watchOS App Transport Security blocks
    // cleartext `URLSession` traffic to a local server.
    func plainHTTPStatusAndBody(method: String, url: URL, body: Data?, contentType: String) async throws -> (status: Int, body: Data) {
        guard let host = url.host else {
            throw WatchInterlaceAPIError.invalidBaseURL("The server URL needs a host name or IP address.")
        }

        let port = url.port ?? 80
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw WatchInterlaceAPIError.invalidBaseURL("The server port is not valid.")
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let request = Self.plainHTTPRequest(method: method, url: url, body: body, contentType: contentType)

        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = WatchPlainHTTPConnectionState(continuation: continuation, connection: connection)
                let queue = DispatchQueue(label: "InterlaceWatch.PlainHTTP.\(UUID().uuidString)")

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
        return (parsed.statusCode, parsed.body)
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
        request.appendString("\r\n\r\n")
        if let body {
            request.append(body)
        }
        return request
    }

    static func receivePlainHTTPResponse(on connection: NWConnection, state: WatchPlainHTTPConnectionState) {
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
            throw WatchInterlaceAPIError.invalidResponse
        }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw WatchInterlaceAPIError.invalidResponse
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard
            let statusLine = lines.first,
            let statusCodeText = statusLine.split(separator: " ").dropFirst().first,
            let statusCode = Int(statusCodeText)
        else {
            throw WatchInterlaceAPIError.invalidResponse
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
                throw WatchInterlaceAPIError.invalidResponse
            }

            let sizeLineData = data.subdata(in: index..<lineRange.lowerBound)
            guard
                let sizeLine = String(data: sizeLineData, encoding: .ascii),
                let sizeText = sizeLine.split(separator: ";").first,
                let chunkSize = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16)
            else {
                throw WatchInterlaceAPIError.invalidResponse
            }

            index = lineRange.upperBound
            if chunkSize == 0 {
                return decoded
            }

            let chunkEnd = index + chunkSize
            guard chunkEnd <= data.endIndex else {
                throw WatchInterlaceAPIError.invalidResponse
            }

            decoded.append(data.subdata(in: index..<chunkEnd))
            index = chunkEnd

            if index < data.endIndex {
                guard data[index..<data.endIndex].starts(with: lineBreak) else {
                    throw WatchInterlaceAPIError.invalidResponse
                }
                index += lineBreak.count
            }
        }

        return decoded
    }
}

private nonisolated final class WatchPlainHTTPConnectionState: @unchecked Sendable {
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

// MARK: - Relay transport (watch asks the iPhone to make the call)

struct WatchRelayTransport: WatchTransport {
    let client: WatchConnectivityClient

    func send(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        body: Data?,
        contentType: String
    ) async throws -> (status: Int, body: Data) {
        var payload: [String: Any] = [
            RelayKey.method: method,
            RelayKey.path: path,
            RelayKey.contentType: contentType
        ]

        if let queryItems, !queryItems.isEmpty {
            var query: [String: String] = [:]
            for item in queryItems where item.value != nil {
                query[item.name] = item.value
            }
            if !query.isEmpty { payload[RelayKey.query] = query }
        }

        if let body { payload[RelayKey.body] = body }

        let reply = try await client.request(payload)

        let status = reply[RelayKey.status] as? Int ?? -1
        if status < 0 {
            let message = reply[RelayKey.error] as? String ?? "The iPhone couldn't reach the server."
            throw WatchInterlaceAPIError.httpStatus(502, message)
        }

        let data = reply[RelayKey.responseBody] as? Data ?? Data()
        return (status, data)
    }
}

// MARK: - WatchConnectivity client

/// Thin async wrapper over `WCSession` on the watch. Used to forward requests to
/// the iPhone and await the reply.
@Observable
final class WatchConnectivityClient: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchConnectivityClient()

    @ObservationIgnored private let session: WCSession = .default

    /// True when the iPhone counterpart can be reached right now. Published so
    /// SwiftUI re-evaluates gating UI (e.g. the "Connect via iPhone" button) as
    /// the link comes and goes — `WCSession` reachability is rarely true on the
    /// very first frame after `activate()`.
    private(set) var isReachable = false

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func request(_ payload: [String: Any]) async throws -> [String: Any] {
        guard WCSession.isSupported() else {
            throw WatchInterlaceAPIError.invalidBaseURL("This device can't talk to an iPhone.")
        }
        guard session.activationState == .activated else {
            throw WatchInterlaceAPIError.invalidBaseURL("iPhone link is still connecting. Try again in a moment.")
        }
        guard session.isReachable else {
            throw WatchInterlaceAPIError.invalidBaseURL("iPhone is not reachable. Open the Interlace app on your iPhone and keep it nearby.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(
                payload,
                replyHandler: { continuation.resume(returning: $0) },
                errorHandler: { continuation.resume(throwing: $0) }
            )
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        refreshReachability()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        refreshReachability()
    }

    /// Delegate callbacks arrive off the main thread; mirror the live `WCSession`
    /// state onto the published property on the main actor so observers update.
    private func refreshReachability() {
        let reachable = session.activationState == .activated && session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }

    func prefixData(_ count: Int) -> Data {
        guard count < self.count else { return self }
        return subdata(in: startIndex..<(startIndex + count))
    }
}
