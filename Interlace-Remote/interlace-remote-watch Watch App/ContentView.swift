import SwiftUI

struct ContentView: View {
    @AppStorage("interlace.watch.baseURL") private var savedBaseURL = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WatchLibraryStore()

    var body: some View {
        Group {
            if store.isConnected {
                WatchConnectedView(store: store, savedBaseURL: $savedBaseURL)
            } else {
                WatchConnectionView(store: store, savedBaseURL: $savedBaseURL)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.configureSavedBaseURL(savedBaseURL)
        }
        .task(id: savedBaseURL) {
            await connectToSavedServerIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard store.isConnected else {
                store.stopPlayerPolling()
                return
            }
            if phase == .active {
                store.startPlayerPolling()
                Task {
                    await store.refreshLibrary(silent: true)
                    await store.refreshPlayer(silent: true)
                }
            } else {
                store.stopPlayerPolling()
            }
        }
        .alert(
            "Interlace Error",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.clearError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                store.clearError()
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func connectToSavedServerIfNeeded() async {
        let trimmedBaseURL = savedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty, !store.isConnected, !store.isConnecting else { return }
        store.configureSavedBaseURL(trimmedBaseURL)
        _ = await store.connect()
    }
}

private enum WatchTab: Hashable {
    case remote
    case library
}

private struct WatchConnectedView: View {
    let store: WatchLibraryStore
    @Binding var savedBaseURL: String
    @State private var selectedTab: WatchTab = .library

    var body: some View {
        TabView(selection: $selectedTab) {
            WatchRemoteView(store: store)
                .tag(WatchTab.remote)

            WatchLibraryView(store: store, savedBaseURL: $savedBaseURL) {
                // Jump to the remote after starting playback.
                selectedTab = .remote
            }
            .tag(WatchTab.library)
        }
        .tabViewStyle(.verticalPage)
    }
}

private struct WatchConnectionView: View {
    let store: WatchLibraryStore
    @Binding var savedBaseURL: String
    @State private var iconPhase = false
    @State private var showingLANEntry = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                // Hero icon with rotating rings — scaled-down version of the iOS login
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 100, height: 100)

                    Circle()
                        .trim(from: 0.05, to: 0.9)
                        .stroke(
                            AngularGradient(
                                colors: [.blue.opacity(0), .blue.opacity(0.5), .blue.opacity(0)],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(iconPhase ? 360 : 0))

                    Circle()
                        .trim(from: 0.1, to: 0.85)
                        .stroke(
                            AngularGradient(
                                colors: [.blue.opacity(0), .blue.opacity(0.35), .blue.opacity(0)],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                        .frame(width: 88, height: 88)
                        .rotationEffect(.degrees(iconPhase ? -300 : 60))

                    Image("Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 52, height: 52)
                        .clipShape(.rect(cornerRadius: 12))
                }
                .onAppear {
                    withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                        iconPhase = true
                    }
                }

                Text("Interlace")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                // Both buttons show ProgressView when connecting so the user
                // knows which path is being tried.
                Button {
                    Task { await store.connect() }
                } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            if store.isConnecting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .tint(.white)
                            } else {
                                Image(systemName: "iphone")
                            }
                        }
                        .frame(width: 16, height: 16)
                        Text(store.isConnecting ? "Connecting…" : "Connect via iPhone")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(store.canRelayThroughPhone ? .green : .gray)
                .disabled(store.isConnecting || !store.canRelayThroughPhone)

                // Tapping opens a focused entry sheet that seeds the common
                // "192.168." prefix so the user only types the last octets.
                Button {
                    showingLANEntry = true
                } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            if store.isConnecting {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: "network")
                            }
                        }
                        .frame(width: 16, height: 16)
                        Text(store.isConnecting ? "Connecting…" : "Connect via LAN")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.isConnecting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingLANEntry) {
            WatchLANEntryView(store: store, savedBaseURL: $savedBaseURL)
        }
    }
}

/// IP entry presented from "Connect via LAN". The `192.168.` prefix and the
/// default `:8080` port are fixed, so the user just fills the last two octets
/// in numeric fields (watchOS shows its number pad for `Int`-bound fields).
private struct WatchLANEntryView: View {
    let store: WatchLibraryStore
    @Binding var savedBaseURL: String
    @Environment(\.dismiss) private var dismiss

    @State private var octet3: Int?
    @State private var octet4: Int?
    @FocusState private var focusedOctet: Int?

    private var isValid: Bool {
        [octet3, octet4].allSatisfy { value in
            guard let value else { return false }
            return (0...255).contains(value)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack(spacing: 2) {
                        Text(verbatim: "192.168.")
                            .foregroundStyle(.secondary)
                        octetField($octet3, placeholder: "1", focus: 3)
                        Text(verbatim: ".")
                        octetField($octet4, placeholder: "1", focus: 4)
                        Text(verbatim: ":8080")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 15, design: .monospaced))

                    Button(action: connect) {
                        HStack(spacing: 6) {
                            if store.isConnecting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .tint(.white)
                            } else {
                                Image(systemName: "network")
                            }
                            Text(store.isConnecting ? "Connecting…" : "Connect")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(store.isConnecting || !isValid)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
            .navigationTitle("Server IP")
        }
        .onAppear {
            seedFromSavedURL()
            if octet3 == nil { focusedOctet = 3 }
        }
    }

    private func octetField(_ value: Binding<Int?>, placeholder: String, focus: Int) -> some View {
        TextField(placeholder, value: value, format: .number.grouping(.never))
            .multilineTextAlignment(.center)
            .frame(width: 40)
            .focused($focusedOctet, equals: focus)
    }

    /// Pre-fill the octets when re-editing an existing `192.168.x.y` address.
    private func seedFromSavedURL() {
        let host = store.baseURLText
            .components(separatedBy: "://").last?
            .components(separatedBy: "/").first?
            .components(separatedBy: ":").first ?? ""
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "192", parts[1] == "168" {
            octet3 = Int(parts[2])
            octet4 = Int(parts[3])
        }
    }

    private func connect() {
        guard let octet3, let octet4 else { return }
        store.baseURLText = "192.168.\(octet3).\(octet4):8080"
        Task {
            if await store.connect() {
                savedBaseURL = store.baseURLText
                dismiss()
            }
        }
    }
}

// MARK: - Remote (Now Playing)

private struct WatchRemoteView: View {
    let store: WatchLibraryStore
    @State private var seekValue = 0.0
    @State private var isSeeking = false
    @State private var volumeValue = 0.0
    @State private var isAdjustingVolume = false

    var body: some View {
        NavigationStack {
            Group {
                if let player = store.player, player.active {
                    playingContent(player)
                } else {
                    idleContent
                }
            }
            .navigationTitle("Now Playing")
        }
        .onChange(of: store.player?.percentage) { _, newValue in
            if !isSeeking { seekValue = newValue ?? 0 }
        }
        .onChange(of: store.player?.volume) { _, newValue in
            if !isAdjustingVolume { volumeValue = Double(newValue ?? 0) }
        }
        .onAppear {
            seekValue = store.player?.percentage ?? 0
            volumeValue = Double(store.player?.volume ?? 0)
        }
    }

    private var idleContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "play.slash")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)

                Text("Nothing Playing")
                    .font(.headline)

                Text("Pick something from the Library to start playback.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
        }
    }

    private func playingContent(_ player: WatchPlayerState) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                titleHeader(player)
                progressSection(player)
                transportRow(player)
                volumeSection(player)
                trackLinks(player)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
    }

    private func titleHeader(_ player: WatchPlayerState) -> some View {
        VStack(spacing: 2) {
            Text(player.title?.isEmpty == false ? player.title! : "Untitled")
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    private func progressSection(_ player: WatchPlayerState) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: min(max(isSeeking ? seekValue : player.percentage, 0), 100), total: 100)
                .tint(.green)

            HStack {
                Text(formatWatchDuration(isSeeking ? seekValue / 100 * player.totalTime : player.time))
                Spacer()
                Text(formatWatchDuration(player.totalTime))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(isSeeking ? .green : .secondary)

            // Digital Crown / +- scrubbing. Commit on release so we don't spam
            // the server with intermediate positions.
            Slider(
                value: $seekValue,
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing {
                        let target = seekValue
                        Task {
                            await store.seek(toPercentage: target)
                            isSeeking = false
                        }
                    }
                }
            )
            .tint(.green)
            .accessibilityLabel("Seek")
        }
    }

    private func transportRow(_ player: WatchPlayerState) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.skip(seconds: -10) }
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 18, weight: .semibold))
            }
            .accessibilityLabel("Skip back 10 seconds")

            Button {
                Task { await store.playPause() }
            } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 22, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
            .accessibilityLabel(player.isPaused ? "Play" : "Pause")

            Button {
                Task { await store.skip(seconds: 10) }
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 18, weight: .semibold))
            }
            .accessibilityLabel("Skip forward 10 seconds")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.top, 2)
    }

    private func volumeSection(_ player: WatchPlayerState) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(player.muted ? .red : .secondary)
                    .frame(width: 18)

                Slider(
                    value: $volumeValue,
                    in: 0...100,
                    step: 1,
                    onEditingChanged: { editing in
                        isAdjustingVolume = editing
                        if !editing {
                            Task { await store.setVolume(Int(volumeValue.rounded())) }
                        }
                    }
                )
                .accessibilityLabel("Volume")

                Button {
                    Task { await store.toggleMute() }
                } label: {
                    Image(systemName: player.muted ? "speaker.slash" : "speaker")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(player.muted ? .red : .gray)
                .accessibilityLabel(player.muted ? "Unmute" : "Mute")
            }

            Button(role: .destructive) {
                Task { await store.stopPlayback() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func trackLinks(_ player: WatchPlayerState) -> some View {
        let audioStreams = player.audioStreams.filter { $0.index != nil }
        let subtitleStreams = player.subtitles.filter { $0.index != nil }

        if !audioStreams.isEmpty || !subtitleStreams.isEmpty {
            VStack(spacing: 8) {
                if !audioStreams.isEmpty {
                    NavigationLink {
                        WatchAudioPicker(store: store, player: player, streams: audioStreams)
                    } label: {
                        Label("Audio", systemImage: "waveform")
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !subtitleStreams.isEmpty {
                    NavigationLink {
                        WatchSubtitlePicker(store: store, player: player, streams: subtitleStreams)
                    } label: {
                        Label("Subtitles", systemImage: "captions.bubble")
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
    }
}

private struct WatchAudioPicker: View {
    let store: WatchLibraryStore
    let player: WatchPlayerState
    let streams: [WatchMediaStream]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(streams) { stream in
                Button {
                    if let index = stream.index {
                        Task { await store.setAudio(index: index) }
                    }
                    dismiss()
                } label: {
                    HStack {
                        Text(stream.displayName)
                            .lineLimit(2)
                        Spacer()
                        if stream.index == player.currentAudioIndex {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle("Audio")
    }
}

private struct WatchSubtitlePicker: View {
    let store: WatchLibraryStore
    let player: WatchPlayerState
    let streams: [WatchMediaStream]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                Task { await store.setSubtitle(index: nil) }
                dismiss()
            } label: {
                HStack {
                    Text("Off")
                    Spacer()
                    if !player.subtitleEnabled {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                    }
                }
            }

            ForEach(streams) { stream in
                Button {
                    if let index = stream.index {
                        Task { await store.setSubtitle(index: index) }
                    }
                    dismiss()
                } label: {
                    HStack {
                        Text(stream.displayName)
                            .lineLimit(2)
                        Spacer()
                        if player.subtitleEnabled, stream.index == player.currentSubtitleIndex {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle("Subtitles")
    }
}

// MARK: - Library

private struct WatchLibraryView: View {
    let store: WatchLibraryStore
    @Binding var savedBaseURL: String
    var onPlay: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                Section {
                    WatchLibraryLocationRow(store: store)
                }

                if store.isLoadingLibrary && store.items.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                } else if store.items.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Empty Folder",
                            systemImage: "folder",
                            description: Text("No library items here.")
                        )
                    }
                } else {
                    Section {
                        ForEach(store.items) { item in
                            WatchLibraryItemRow(item: item) {
                                Task {
                                    await store.open(item)
                                    if !item.isDirectory {
                                        onPlay()
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        savedBaseURL = ""
                        store.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            }
            .navigationTitle("Library")
            .refreshable {
                await store.refreshLibrary()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await store.refreshLibrary()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh library")
                }
            }
        }
    }
}

private struct WatchLibraryLocationRow: View {
    let store: WatchLibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.connectedURLLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack {
                Label(store.locationLabel, systemImage: store.libraryPath.isEmpty ? "externaldrive" : "folder")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if !store.libraryPath.isEmpty {
                    Button {
                        Task {
                            await store.goUp()
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Go up one folder")
                }
            }

            if !store.libraryPath.isEmpty {
                Button {
                    Task {
                        await store.goToRoot()
                    }
                } label: {
                    Label("Downloads", systemImage: "house")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

private struct WatchLibraryItemRow: View {
    let item: WatchLibraryItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.isDirectory ? "folder.fill" : "play.rectangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(item.isDirectory ? .blue : .green)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)

                    if item.isDirectory {
                        Text("Folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if item.size > 0 {
                        Text(formatWatchBytes(item.size))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Play")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityLabel(item.isDirectory ? "Open \(item.name)" : "Play \(item.name)")
    }
}

private func formatWatchBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unitIndex = 0

    while value >= 1024, unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }

    if unitIndex == 0 {
        return "\(bytes) B"
    }

    return String(format: "%.1f %@", value, units[unitIndex])
}

private func formatWatchDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

#Preview {
    ContentView()
}
