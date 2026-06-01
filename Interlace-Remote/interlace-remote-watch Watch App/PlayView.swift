import SwiftUI

struct PlayView: View {
    let store: WatchLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var seekValue = 0.0
    @State private var isSeeking = false
    @State private var volumeValue = 0.0
    @State private var isAdjustingVolume = false

    var body: some View {
        // Pushed onto the library's NavigationStack, so no stack of its own.
        Group {
            if let player = store.player, player.active {
                playingContent(player)
            } else {
                idleContent
            }
        }
        .navigationTitle("Now Playing")
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
            // Single scrubber doubles as the progress bar. Commit on release so
            // we don't spam intermediate seeks.
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

            HStack {
                Text(formatDuration(isSeeking ? seekValue / 100 * player.totalTime : player.time))
                Spacer()
                Text(formatDuration(player.totalTime))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(isSeeking ? .green : .secondary)
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
                Task {
                    await store.stopPlayback()
                    dismiss()
                }
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
                        AudioPicker(store: store, player: player, streams: audioStreams)
                    } label: {
                        Label("Audio", systemImage: "waveform")
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !subtitleStreams.isEmpty {
                    NavigationLink {
                        SubtitlePicker(store: store, player: player, streams: subtitleStreams)
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

    private func formatDuration(_ seconds: Double) -> String {
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
}

private struct AudioPicker: View {
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

private struct SubtitlePicker: View {
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
