import Foundation
import Observation

@Observable
@MainActor
final class WatchLibraryStore {
    var baseURLText = ""
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isLoadingLibrary = false
    private(set) var libraryPath = ""
    private(set) var items: [WatchLibraryItem] = []
    private(set) var lastPlayedItemName: String?
    private(set) var player: WatchPlayerState?
    private(set) var isLoadingPlayer = false
    private(set) var usingPhoneRelay = false
    private(set) var connectionLabel = ""
    var errorMessage: String?

    @ObservationIgnored private var api: WatchInterlaceAPI?
    @ObservationIgnored private var playerPollTask: Task<Void, Never>?
    @ObservationIgnored private let connectivity = WatchConnectivityClient.shared

    var isPlaybackActive: Bool {
        player?.active == true
    }

    var connectedURLLabel: String {
        connectionLabel.isEmpty ? baseURLText : connectionLabel
    }

    var locationLabel: String {
        libraryPath.isEmpty ? "Downloads" : libraryPath
    }

    /// Whether the watch can fall back to relaying through the iPhone right now.
    var canRelayThroughPhone: Bool {
        connectivity.isReachable
    }

    func configureSavedBaseURL(_ savedBaseURL: String) {
        guard baseURLText.isEmpty else { return }
        baseURLText = savedBaseURL
    }

    /// Tries to reach the server directly first (works on the home LAN), then
    /// falls back to relaying through the paired iPhone, which makes the call
    /// with its own network — so the watch works away from home as long as the
    /// iPhone can reach the server (e.g. over VPN / Tailscale).
    @discardableResult
    func connect() async -> Bool {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Direct, if a server URL has been entered.
        if !trimmed.isEmpty, let normalizedURL = try? WatchInterlaceAPI.normalizedBaseURL(from: trimmed) {
            let directAPI = WatchInterlaceAPI(transport: WatchDirectTransport(baseURL: normalizedURL))
            if await probe(directAPI) {
                let label = WatchInterlaceAPI.displayString(for: normalizedURL)
                await finishConnecting(with: directAPI, relay: false, label: label, savedURL: label)
                return true
            }
        }

        // 2. Relay through the iPhone.
        if connectivity.isReachable {
            let relayAPI = WatchInterlaceAPI(transport: WatchRelayTransport(client: connectivity))
            if await probe(relayAPI) {
                await finishConnecting(with: relayAPI, relay: true, label: "via iPhone", savedURL: nil)
                return true
            }
        }

        // 3. Nothing worked.
        api = nil
        isConnected = false
        errorMessage = connectionFailureMessage(triedDirect: !trimmed.isEmpty)
        return false
    }

    func disconnect() {
        stopPlayerPolling()
        api = nil
        isConnected = false
        usingPhoneRelay = false
        connectionLabel = ""
        items = []
        libraryPath = ""
        lastPlayedItemName = nil
        player = nil
        errorMessage = nil
    }

    func refreshLibrary(path: String? = nil, silent: Bool = false) async {
        guard let api else { return }
        if !silent {
            isLoadingLibrary = true
        }
        defer {
            if !silent {
                isLoadingLibrary = false
            }
        }

        let targetPath = normalizeLibraryPath(path ?? libraryPath)
        do {
            let response = try await api.library(path: targetPath)
            items = response.items.sorted(by: librarySort)
            libraryPath = targetPath
            if !silent {
                errorMessage = nil
            }
        } catch {
            if !silent {
                errorMessage = error.localizedDescription
            }
        }
    }

    func open(_ item: WatchLibraryItem) async {
        if item.isDirectory {
            await refreshLibrary(path: item.rel.isEmpty ? item.path : item.rel)
        } else {
            await play(item)
        }
    }

    func goUp() async {
        guard !libraryPath.isEmpty else { return }
        var parts = libraryPath.split(separator: "/").map(String.init)
        _ = parts.popLast()
        await refreshLibrary(path: parts.joined(separator: "/"))
    }

    func goToRoot() async {
        await refreshLibrary(path: "")
    }

    func play(_ item: WatchLibraryItem) async {
        guard !item.isDirectory else { return }

        do {
            try await requireAPI().play(path: item.path)
            lastPlayedItemName = item.name
            errorMessage = nil
            // Give Kodi a moment to load the file before asking for state.
            try? await Task.sleep(for: .milliseconds(600))
            await refreshPlayer(silent: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Player

    func refreshPlayer(silent: Bool = false) async {
        guard let api else { return }
        if !silent { isLoadingPlayer = true }
        defer { if !silent { isLoadingPlayer = false } }

        do {
            player = try await api.player()
            if !silent { errorMessage = nil }
        } catch {
            if !silent { errorMessage = error.localizedDescription }
        }
    }

    func startPlayerPolling() {
        guard playerPollTask == nil else { return }
        playerPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.refreshPlayer(silent: true)
            }
        }
    }

    func stopPlayerPolling() {
        playerPollTask?.cancel()
        playerPollTask = nil
    }

    func playPause() async {
        // Optimistically flip the speed so the transport button reacts instantly.
        if let current = player {
            player = current.togglingPlayback()
        }
        await runPlayerAction { try await $0.playPause() }
    }

    func stopPlayback() async {
        await runPlayerAction { try await $0.stop() }
    }

    func skip(seconds: Double) async {
        guard let current = player, current.totalTime > 0 else { return }
        // Optimistically nudge the displayed position; the real seek is relative
        // on Kodi's side so it lands accurately regardless of our polled clock.
        let target = min(max(current.time + seconds, 0), current.totalTime)
        let percentage = (target / current.totalTime) * 100
        player = current.seeking(toPercentage: percentage)
        await runPlayerAction { try await $0.skip(seconds: Int(seconds)) }
    }

    func seek(toPercentage percentage: Double) async {
        if let current = player {
            player = current.seeking(toPercentage: percentage)
        }
        await runPlayerAction { try await $0.seek(percentage: percentage) }
    }

    func setVolume(_ level: Int) async {
        if let current = player {
            player = current.settingVolume(level)
        }
        await runPlayerAction { try await $0.setVolume(level: level) }
    }

    func toggleMute() async {
        guard let current = player else { return }
        let nextMuted = !current.muted
        player = current.settingMuted(nextMuted)
        await runPlayerAction { try await $0.setMute(nextMuted) }
    }

    func setAudio(index: Int) async {
        await runPlayerAction { try await $0.setAudio(index: index) }
    }

    func setSubtitle(index: Int?) async {
        await runPlayerAction { api in
            if let index {
                try await api.setSubtitle(index: index)
            } else {
                try await api.setSubtitleOff()
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }
}

private extension WatchLibraryStore {
    func requireAPI() throws -> WatchInterlaceAPI {
        guard let api else {
            throw WatchInterlaceAPIError.invalidBaseURL("Connect to an Interlace server first.")
        }
        return api
    }

    /// A quick connectivity check, bounded so a dead direct route doesn't make
    /// the user wait the full request timeout before we try the iPhone relay.
    func probe(_ candidate: WatchInterlaceAPI) async -> Bool {
        do {
            try await withTimeout(seconds: 4) { try await candidate.status() }
            return true
        } catch {
            return false
        }
    }

    func finishConnecting(with client: WatchInterlaceAPI, relay: Bool, label: String, savedURL: String?) async {
        api = client
        usingPhoneRelay = relay
        connectionLabel = label
        if let savedURL { baseURLText = savedURL }
        isConnected = true
        await refreshLibrary(path: "", silent: true)
        await refreshPlayer(silent: true)
        startPlayerPolling()
    }

    func connectionFailureMessage(triedDirect: Bool) -> String {
        if connectivity.isReachable {
            return "Couldn't reach Interlace. Check the server is running and the URL is correct."
        }
        if triedDirect {
            return "Couldn't reach Interlace directly, and your iPhone isn't available to relay. Connect to the server's network, or open the Interlace app on your iPhone and keep it nearby."
        }
        return "Open the Interlace app on your iPhone and keep it nearby to connect through it, or enter the server URL to connect directly."
    }

    func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw WatchInterlaceAPIError.invalidResponse
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Sends a player command, then re-reads the real state so the optimistic
    /// UI converges on what Kodi actually did (or surfaces the failure).
    func runPlayerAction(_ action: (WatchInterlaceAPI) async throws -> Void) async {
        guard let api else { return }
        do {
            try await action(api)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshPlayer(silent: true)
    }

    func normalizeLibraryPath(_ path: String) -> String {
        path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func librarySort(_ lhs: WatchLibraryItem, _ rhs: WatchLibraryItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
