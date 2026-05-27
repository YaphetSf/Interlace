//
//  InterlaceStore.swift
//  Interlace-Remote
//

import Foundation
import Observation

@Observable
@MainActor
final class InterlaceStore {
    var baseURLText = ""
    private(set) var isConnected = false
    private(set) var status: StatusResponse?
    private(set) var capabilities: CapabilitiesResponse?
    private(set) var downloads: [DownloadItem] = []
    private(set) var library: [LibraryItem] = []
    private(set) var libraryPath = ""
    private(set) var disk: DiskInfo?
    private(set) var systemInfo: SystemInfo?
    private(set) var player: PlayerState?
    private(set) var uploads: [UploadTask] = []
    private(set) var subtitleDelaySteps = 0
    private(set) var audioDelaySteps = 0
    var errorMessage: String?

    private(set) var isConnecting = false
    private(set) var isRefreshing = false
    private(set) var isLoadingDownloads = false
    private(set) var isLoadingLibrary = false
    private(set) var isLoadingPlayer = false
    private(set) var isAddingDownload = false
    private(set) var isUploading = false

    @ObservationIgnored private var api: InterlaceAPI?
    @ObservationIgnored private var downloadsPollTask: Task<Void, Never>?
    @ObservationIgnored private var playerPollTask: Task<Void, Never>?
    @ObservationIgnored private var systemPollTask: Task<Void, Never>?
    @ObservationIgnored private var lastPlayerFile: String?

    var connectedURLLabel: String {
        guard let api else { return baseURLText }
        return InterlaceAPI.displayString(for: api.baseURL)
    }

    var statusLabel: String {
        status?.summary.capitalized ?? (isConnected ? "Connected" : "Disconnected")
    }

    var libraryLocationLabel: String {
        libraryPath.isEmpty ? "Downloads" : "/\(libraryPath)"
    }

    func configureSavedBaseURL(_ savedBaseURL: String) {
        guard baseURLText.isEmpty else { return }
        baseURLText = savedBaseURL
    }

    @discardableResult
    func connect() async -> Bool {
        set(\.isConnecting, to: true)
        set(\.errorMessage, to: nil)
        defer { set(\.isConnecting, to: false) }

        do {
            let normalizedURL = try InterlaceAPI.normalizedBaseURL(from: baseURLText)
            let client = InterlaceAPI(baseURL: normalizedURL)
            let status = try await client.status()

            api = client
            set(\.baseURLText, to: InterlaceAPI.displayString(for: normalizedURL))
            set(\.status, to: status)
            set(\.isConnected, to: true)

            startPolling()
            await refreshAll(silent: true)
            return true
        } catch {
            stopPolling()
            api = nil
            set(\.isConnected, to: false)
            setError(error)
            return false
        }
    }

    func disconnect() {
        stopPolling()
        set(\.isConnected, to: false)
        api = nil
        set(\.status, to: nil)
        set(\.capabilities, to: nil)
        set(\.downloads, to: [])
        set(\.library, to: [])
        set(\.libraryPath, to: "")
        set(\.disk, to: nil)
        set(\.systemInfo, to: nil)
        set(\.player, to: nil)
        set(\.uploads, to: [])
        set(\.subtitleDelaySteps, to: 0)
        set(\.audioDelaySteps, to: 0)
        lastPlayerFile = nil
        set(\.errorMessage, to: nil)
    }

    func refreshAll(silent: Bool = false) async {
        guard let api else { return }
        if isRefreshing { return }
        set(\.isRefreshing, to: true)
        defer { set(\.isRefreshing, to: false) }

        var failures: [String] = []
        let currentLibraryPath = libraryPath

        async let statusResult = capture {
            try await api.status()
        }
        async let capabilitiesResult = capture {
            try await api.capabilities()
        }
        async let downloadsResult = capture {
            try await api.downloads()
        }
        async let libraryResult = capture {
            try await api.library(path: currentLibraryPath)
        }
        async let playerResult = capture {
            try await api.player()
        }
        async let systemResult = capture {
            try await api.systemStats()
        }

        switch await statusResult {
        case .success(let nextStatus):
            set(\.status, to: nextStatus)
        case .failure(let error):
            failures.append("Status: \(error.localizedDescription)")
        }

        if case .success(let nextCapabilities) = await capabilitiesResult {
            set(\.capabilities, to: nextCapabilities)
        }

        switch await downloadsResult {
        case .success(let nextDownloads):
            set(\.downloads, to: nextDownloads)
        case .failure(let error):
            failures.append("Downloads: \(error.localizedDescription)")
        }

        switch await libraryResult {
        case .success(let response):
            set(\.library, to: response.items)
            set(\.disk, to: response.disk)
        case .failure(let error):
            failures.append("Library: \(error.localizedDescription)")
        }

        switch await playerResult {
        case .success(let nextPlayer):
            updatePlayerState(nextPlayer)
        case .failure(let error):
            failures.append("Player: \(error.localizedDescription)")
        }

        if case .success(let nextSystem) = await systemResult {
            set(\.systemInfo, to: nextSystem)
        }

        if !silent {
            set(\.errorMessage, to: failures.first)
        }
    }

    func refreshDownloads(silent: Bool = false) async {
        guard let api else { return }
        if !silent { set(\.isLoadingDownloads, to: true) }
        defer { if !silent { set(\.isLoadingDownloads, to: false) } }

        do {
            set(\.downloads, to: try await api.downloads())
            if !silent { set(\.errorMessage, to: nil) }
        } catch {
            if !silent { setError(error) }
        }
    }

    func refreshLibrary(path: String? = nil, silent: Bool = false) async {
        guard let api else { return }
        if !silent { set(\.isLoadingLibrary, to: true) }
        defer { if !silent { set(\.isLoadingLibrary, to: false) } }

        let targetPath = normalizeLibraryPath(path ?? libraryPath)
        do {
            let response = try await api.library(path: targetPath)
            set(\.libraryPath, to: targetPath)
            set(\.library, to: response.items)
            set(\.disk, to: response.disk)
            if !silent { set(\.errorMessage, to: nil) }
        } catch {
            if !silent { setError(error) }
        }
    }

    func refreshPlayer(silent: Bool = false) async {
        guard let api else { return }
        if !silent { set(\.isLoadingPlayer, to: true) }
        defer { if !silent { set(\.isLoadingPlayer, to: false) } }

        do {
            updatePlayerState(try await api.player())
            if !silent { set(\.errorMessage, to: nil) }
        } catch {
            if !silent { setError(error) }
        }
    }

    func refreshSystem(silent: Bool = false) async {
        guard let api else { return }
        do {
            set(\.systemInfo, to: try await api.systemStats())
        } catch {
            if !silent { setError(error) }
        }
    }

    func addURI(_ uri: String) async -> Bool {
        let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURI.isEmpty else {
            set(\.errorMessage, to: "Enter a magnet link, torrent URL, or media URL.")
            return false
        }

        do {
            set(\.isAddingDownload, to: true)
            defer { set(\.isAddingDownload, to: false) }
            try await requireAPI().addDownload(uri: trimmedURI)
            await refreshDownloads()
            return true
        } catch {
            setError(error)
            return false
        }
    }

    func addTorrent(fileURL: URL) async {
        do {
            set(\.isAddingDownload, to: true)
            defer { set(\.isAddingDownload, to: false) }

            let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            try await requireAPI().uploadTorrent(fileURL: fileURL)
            await refreshDownloads()
        } catch {
            setError(error)
        }
    }

    func pause(_ download: DownloadItem) async {
        await performDownloadAction {
            try await requireAPI().pauseDownload(gid: download.gid)
        }
    }

    func resume(_ download: DownloadItem) async {
        await performDownloadAction {
            try await requireAPI().resumeDownload(gid: download.gid)
        }
    }

    func remove(_ download: DownloadItem) async {
        await performDownloadAction {
            try await requireAPI().removeDownload(gid: download.gid)
        }
    }

    func play(_ item: LibraryItem) async {
        if item.isDirectory {
            await openDirectory(item)
            return
        }

        do {
            try await requireAPI().play(path: item.path)
            await refreshPlayer()
        } catch {
            setError(error)
        }
    }

    func deleteLibraryItem(_ item: LibraryItem) async {
        do {
            try await requireAPI().deleteLibraryItem(path: item.path)
            await refreshLibrary()
        } catch {
            setError(error)
        }
    }

    func openDirectory(_ item: LibraryItem) async {
        guard item.isDirectory else { return }
        await refreshLibrary(path: item.rel.isEmpty ? item.path : item.rel)
    }

    func goToLibraryPath(_ path: String) async {
        await refreshLibrary(path: path)
    }

    func goUpLibrary() async {
        guard !libraryPath.isEmpty else { return }
        var parts = libraryPath.split(separator: "/").map(String.init)
        _ = parts.popLast()
        await refreshLibrary(path: parts.joined(separator: "/"))
    }

    func uploadFiles(fileURLs: [URL]) async {
        guard !fileURLs.isEmpty else { return }
        set(\.isUploading, to: true)
        defer { set(\.isUploading, to: false) }

        for fileURL in fileURLs {
            await uploadSelectedURL(fileURL, to: libraryPath)
        }

        await refreshLibrary(silent: true)
    }

    func uploadSubtitle(for item: LibraryItem, fileURL: URL) async {
        guard !item.isDirectory else { return }
        let id = addUpload(name: "Subtitle for \(item.name)", size: fileSize(fileURL))

        do {
            try await withSecurityScopedAccess(fileURL) {
                try await requireAPI().uploadSubtitle(videoPath: item.path, fileURL: fileURL)
            }
            finishUpload(id)
            await refreshPlayer(silent: true)
        } catch {
            failUpload(id, error: error)
            setError(error)
        }
    }

    func playPause() async {
        do {
            try await requireAPI().playPause()
            await refreshPlayer()
        } catch {
            setError(error)
        }
    }

    func stop() async {
        do {
            try await requireAPI().stop()
            await refreshPlayer()
        } catch {
            setError(error)
        }
    }

    func seek(to percentage: Double) async {
        do {
            try await requireAPI().seek(percentage: percentage)
            await refreshPlayer()
        } catch {
            setError(error)
        }
    }

    func setVolume(_ level: Int) async {
        do {
            try await requireAPI().setVolume(level: level)
            await refreshPlayer()
        } catch {
            setError(error)
        }
    }

    func setMute(_ muted: Bool) async {
        do {
            try await requireAPI().setMute(muted)
            await refreshPlayer()
        } catch {
            setError(error)
        }
    }

    func setAudio(index: Int) async {
        do {
            try await requireAPI().setAudio(index: index)
            await refreshPlayer()
        } catch {
            setError(error)
        }
    }

    func setVideo(index: Int) async {
        do {
            try await requireAPI().setVideo(index: index)
            await refreshPlayer()
        } catch {
            setError(error)
        }
    }

    func setSubtitle(index: Int?) async {
        do {
            if let index {
                try await requireAPI().setSubtitle(index: index)
            } else {
                try await requireAPI().setSubtitleOff()
            }
            await refreshPlayer()
        } catch {
            setError(error)
        }
    }

    func nudgeSubtitleDelay(_ direction: DelayDirection) async {
        do {
            try await requireAPI().subtitleDelay(direction)
            set(\.subtitleDelaySteps, to: subtitleDelaySteps + (direction == .plus ? 1 : -1))
        } catch {
            setError(error)
        }
    }

    func nudgeAudioDelay(_ direction: DelayDirection) async {
        do {
            try await requireAPI().audioDelay(direction)
            set(\.audioDelaySteps, to: audioDelaySteps + (direction == .plus ? 1 : -1))
        } catch {
            setError(error)
        }
    }

    func resetSubtitleDelayEstimate() {
        set(\.subtitleDelaySteps, to: 0)
    }

    func resetAudioDelayEstimate() {
        set(\.audioDelaySteps, to: 0)
    }

    func clearError() {
        set(\.errorMessage, to: nil)
    }

    deinit {
        downloadsPollTask?.cancel()
        playerPollTask?.cancel()
        systemPollTask?.cancel()
    }
}

private extension InterlaceStore {
    func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<InterlaceStore, Value>, to nextValue: Value) {
        guard self[keyPath: keyPath] != nextValue else { return }
        self[keyPath: keyPath] = nextValue
    }

    func capture<Value>(_ operation: () async throws -> Value) async -> Result<Value, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    func refreshStatusAndCapabilities(silent: Bool) async {
        guard let api else { return }

        do {
            set(\.status, to: try await api.status())
            if let nextCapabilities = try? await api.capabilities() {
                set(\.capabilities, to: nextCapabilities)
            }
            if !silent { set(\.errorMessage, to: nil) }
        } catch {
            if !silent { setError(error) }
        }
    }

    func performDownloadAction(_ action: () async throws -> Void) async {
        do {
            try await action()
            await refreshDownloads()
        } catch {
            setError(error)
        }
    }

    func uploadSelectedURL(_ fileURL: URL, to path: String) async {
        do {
            try await withSecurityScopedAccess(fileURL) {
                if isDirectory(fileURL) {
                    let files = regularFiles(in: fileURL)
                    for childURL in files {
                        await uploadFile(
                            childURL,
                            to: path,
                            remoteFileName: remoteFileName(for: childURL, root: fileURL)
                        )
                    }
                } else {
                    await uploadFile(fileURL, to: path)
                }
            }
        } catch {
            setError(error)
        }
    }

    func uploadFile(_ fileURL: URL, to path: String, remoteFileName: String? = nil) async {
        let fileName = remoteFileName ?? fileURL.lastPathComponent
        let id = addUpload(name: fileName, size: fileSize(fileURL))

        do {
            let data = try Data(contentsOf: fileURL)
            try await requireAPI().upload(fileName: fileName, data: data, to: path)
            finishUpload(id)
        } catch {
            failUpload(id, error: error)
            setError(error)
        }
    }

    func addUpload(name: String, size: Int64) -> UUID {
        let id = UUID()
        uploads.insert(
            UploadTask(
                id: id,
                name: name.isEmpty ? "Upload" : name,
                size: size,
                progress: 0,
                status: .uploading,
                error: nil
            ),
            at: 0
        )
        return id
    }

    func finishUpload(_ id: UUID) {
        updateUpload(id) { upload in
            upload.progress = 100
            upload.status = .done
            upload.error = nil
        }
        scheduleUploadRemoval(id)
    }

    func failUpload(_ id: UUID, error: Error) {
        updateUpload(id) { upload in
            upload.status = .error
            upload.error = error.localizedDescription
        }
    }

    func updateUpload(_ id: UUID, update: (inout UploadTask) -> Void) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        update(&uploads[index])
    }

    func scheduleUploadRemoval(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.removeUpload(id)
        }
    }

    func removeUpload(_ id: UUID) {
        uploads.removeAll { $0.id == id }
    }

    func withSecurityScopedAccess<T>(_ fileURL: URL, operation: () async throws -> T) async throws -> T {
        let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }

    func fileSize(_ fileURL: URL) -> Int64 {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    func isDirectory(_ fileURL: URL) -> Bool {
        let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }

    func regularFiles(in folderURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? url : nil
        }
    }

    func remoteFileName(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let relativePath: String

        if filePath.hasPrefix(rootPath + "/") {
            relativePath = String(filePath.dropFirst(rootPath.count + 1))
        } else {
            relativePath = fileURL.lastPathComponent
        }

        let folderName = root.lastPathComponent
        return folderName.isEmpty ? relativePath : "\(folderName)/\(relativePath)"
    }

    func normalizeLibraryPath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t\r"))
    }

    func updatePlayerState(_ nextPlayer: PlayerState) {
        let nextFile = nextPlayer.file ?? ""
        if nextFile != lastPlayerFile {
            lastPlayerFile = nextFile
            set(\.subtitleDelaySteps, to: 0)
            set(\.audioDelaySteps, to: 0)
        }
        set(\.player, to: nextPlayer)
    }

    func requireAPI() throws -> InterlaceAPI {
        guard let api else {
            throw InterlaceAPIError.invalidBaseURL("Connect to an Interlace server first.")
        }
        return api
    }

    func startPolling() {
        stopPolling()

        downloadsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.refreshDownloads(silent: true)
            }
        }

        playerPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.refreshPlayer(silent: true)
            }
        }

        systemPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.refreshSystem(silent: true)
            }
        }
    }

    func stopPolling() {
        downloadsPollTask?.cancel()
        downloadsPollTask = nil
        playerPollTask?.cancel()
        playerPollTask = nil
        systemPollTask?.cancel()
        systemPollTask = nil
    }

    func setError(_ error: Error) {
        set(\.errorMessage, to: error.localizedDescription)
    }
}

struct UploadTask: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let size: Int64
    var progress: Double
    var status: UploadTaskStatus
    var error: String?
}

enum UploadTaskStatus: Equatable, Sendable {
    case uploading
    case done
    case error
}
