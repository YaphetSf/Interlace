//
//  WatchRelayServer.swift
//  Interlace-Remote
//
//  Bridges the Apple Watch app to the Interlace server. The watch sends a
//  relayed HTTP request over WatchConnectivity; this object performs that
//  request from the iPhone — so it uses the phone's own network route to the
//  server (including any VPN / Tailscale tunnel) — and replies with the result.
//
//  watchOS network proxying does *not* traverse the phone's VPN, which is why
//  the relay has to be an explicit app-to-app message rather than just letting
//  the watch make the request "through" the phone at the network layer.
//

import Foundation
import WatchConnectivity

/// Shared dictionary keys for relayed requests/replies. The watch side
/// (`RelayKey` in WatchTransport.swift) declares an identical set — keep in sync.
private enum RelayKey {
    static let method = "m"
    static let path = "p"
    static let query = "q"
    static let body = "b"
    static let contentType = "c"
    static let status = "s"
    static let responseBody = "d"
    static let error = "e"
}

final class WatchRelayServer: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchRelayServer()

    /// Matches the iPhone app's `@AppStorage("interlace.baseURL")`.
    private let baseURLDefaultsKey = "interlace.baseURL"

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let method = message[RelayKey.method] as? String ?? "GET"
        let path = message[RelayKey.path] as? String ?? ""
        let query = message[RelayKey.query] as? [String: String]
        let body = message[RelayKey.body] as? Data
        let contentType = message[RelayKey.contentType] as? String ?? "application/json"

        Task {
            do {
                let api = try makeAPI()
                let queryItems = query?.map { URLQueryItem(name: $0.key, value: $0.value) }
                let result = try await api.rawRequest(
                    method: method,
                    path: path,
                    queryItems: queryItems,
                    body: body,
                    contentType: contentType
                )
                replyHandler([
                    RelayKey.status: result.status,
                    RelayKey.responseBody: result.body
                ])
            } catch {
                replyHandler([
                    RelayKey.status: -1,
                    RelayKey.error: error.localizedDescription
                ])
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so the relay keeps working after the watch re-pairs.
        WCSession.default.activate()
    }

    // MARK: Helpers

    private func makeAPI() throws -> InterlaceAPI {
        let savedURL = UserDefaults.standard.string(forKey: baseURLDefaultsKey) ?? ""
        guard !savedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterlaceAPIError.invalidBaseURL("No Interlace server is set up on your iPhone yet.")
        }
        let baseURL = try InterlaceAPI.normalizedBaseURL(from: savedURL)
        return InterlaceAPI(baseURL: baseURL)
    }
}
