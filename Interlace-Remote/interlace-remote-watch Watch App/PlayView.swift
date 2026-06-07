import SwiftUI

struct PlayView: View {
    let store: WatchLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var seekValue = 0.0
    @State private var isSeeking = false
    @State private var volumeValue = 0.0
    @State private var isAdjustingVolume = false
    @State private var seekActive = false

    var body: some View {
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
                stopButton
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

    // MARK: - Progress

    private func progressSection(_ player: WatchPlayerState) -> some View {
        VStack(spacing: 4) {
            if seekActive {
                seekBar(active: true)
                    .onTapGesture { seekActive = false }
            } else {
                seekBar(active: false)
                    .onTapGesture { seekActive = true }
            }

            HStack {
                Text(formatDuration(isSeeking ? seekValue / 100 * player.totalTime : player.time))
                Spacer()
                Text(formatDuration(player.totalTime))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(seekActive ? .green : .secondary)
        }
        .onChange(of: seekActive) { _, active in
            if !active, isSeeking {
                isSeeking = false
                Task { await store.seek(toPercentage: seekValue) }
            }
        }
    }

    @ViewBuilder
    private func seekBar(active: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.green.opacity(active ? 0.25 : 0.15))
                    .frame(height: active ? 6 : 4)
                Capsule()
                    .fill(active ? .green : .green.opacity(0.7))
                    .frame(width: max(active ? 8 : 6, geo.size.width * seekValue / 100), height: active ? 6 : 4)
                if active {
                    Circle()
                        .fill(.green)
                        .frame(width: 16, height: 16)
                        .offset(x: geo.size.width * seekValue / 100 - 8)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(.green)
                }
            }
            .if(active) {
                $0.gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .local)
                        .onChanged { value in
                            let pct = (value.location.x / geo.size.width * 100).clamped(to: 0...100)
                            seekValue = pct
                            isSeeking = true
                        }
                        .onEnded { _ in
                            isSeeking = false
                            Task { await store.seek(toPercentage: seekValue) }
                        }
                )
            }
        }
        .frame(height: active ? 30 : 12)
    }

    // MARK: - Transport

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

    // MARK: - Volume

    private func volumeSection(_ player: WatchPlayerState) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.toggleMute() }
            } label: {
                Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(player.muted ? .red : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.muted ? "Unmute" : "Mute")

            Slider(value: $volumeValue, in: 0...100, step: 1) {
                Text("Volume")
            } onEditingChanged: { editing in
                isAdjustingVolume = editing
                if !editing {
                    Task { await store.setVolume(Int(volumeValue.rounded())) }
                }
            }
            .focusable(true)
            .tint(.blue)
        }
    }

    // MARK: - Track links

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

    // MARK: - Stop

    private var stopButton: some View {
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
        .padding(.top, 4)
    }

    // MARK: - Helpers

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

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
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
