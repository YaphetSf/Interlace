import SwiftUI

struct PlayerView: View {
    let store: InterlaceStore
    @State private var seekValue = 0.0
    @State private var isSeeking = false
    @State private var volumeValue = 0.0
    @State private var isAdjustingVolume = false
    @State private var showSyncSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            ScrollView {
                LazyVStack(spacing: 24) {
                    if let player = store.player {
                        if player.active {
                            // NOW PLAYING HEADER
                            nowPlaying(player)
                            
                            // SEEK TIMING SLIDER
                            seekControls(player)
                            
                            // VOLUME ADJUSTER
                            volumeControls(player)
                            
                            // TRANSPORT DIAL DECK
                            transportControls(player)
                            
                            // HORIZONTAL CHANNELS
                            channelControls(player)
                        } else {
                            VStack(spacing: 16) {
                                Spacer()
                                    .frame(height: 100)
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: 48))
                                    .foregroundStyle(Color(white: 0.25))
                                
                                Text("请播个视频先")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color(white: 0.4))
                            }
                            .padding(.horizontal, 24)
                        }
                    } else {
                        VStack(spacing: 16) {
                            Spacer()
                                .frame(height: 60)
                            ProgressView()
                                .tint(.white)
                        }
                    }
                }
                .padding(16)
                Spacer()
                    .frame(height: 40)
            }
            .refreshable {
                await store.refreshPlayer()
            }
        }
        .sheet(isPresented: $showSyncSheet) {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 28) {
                    VStack(spacing: 4) {
                        Text("SYNCHRONIZATION")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(white: 0.4))
                            .tracking(1.5)
                        
                        Divider()
                            .background(Color(white: 0.16))
                    }
                    
                    DelayControlRow(
                        title: "Subtitle Delay",
                        value: formatDelayEstimate(store.subtitleDelaySteps),
                        onMinus: { Task { await store.nudgeSubtitleDelay(.minus) } },
                        onReset: { store.resetSubtitleDelayEstimate() },
                        onPlus: { Task { await store.nudgeSubtitleDelay(.plus) } }
                    )
                    
                    DelayControlRow(
                        title: "Audio Delay",
                        value: formatDelayEstimate(store.audioDelaySteps),
                        onMinus: { Task { await store.nudgeAudioDelay(.minus) } },
                        onReset: { store.resetAudioDelayEstimate() },
                        onPlus: { Task { await store.nudgeAudioDelay(.plus) } }
                    )
                }
                .padding(24)
            }
            .presentationDetents([.height(200)])
        }
        .onAppear {
            syncControls()
        }
        .onChange(of: store.player?.percentage) { _, _ in
            if !isSeeking {
                seekValue = store.player?.percentage ?? 0
            }
        }
        .onChange(of: store.player?.volume) { _, _ in
            if !isAdjustingVolume {
                volumeValue = Double(store.player?.volume ?? 50)
            }
        }
    }

    private func nowPlaying(_ player: PlayerState) -> some View {
        VStack(spacing: 6) {
            Text(player.title?.isEmpty == false ? player.title! : "Untitled Playback")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if let file = player.file, !file.isEmpty {
                Text(file.split(separator: "/").last.map(String.init) ?? file)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func seekControls(_ player: PlayerState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Slider(value: $seekValue, in: 0...100, onEditingChanged: { editing in
                isSeeking = editing
                if !editing {
                    Task {
                        await store.seek(to: seekValue)
                    }
                }
            })
            .tint(Color(red: 0, green: 0.55, blue: 1))

            HStack {
                Text(formatDuration(player.time))
                Spacer()
                Text("-\(formatDuration(player.totalTime - player.time))")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(white: 0.5))
        }
    }

    private func volumeControls(_ player: PlayerState?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: player?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.4))

            Slider(value: $volumeValue, in: 0...100, step: 1, onEditingChanged: { editing in
                isAdjustingVolume = editing
                if !editing {
                    Task {
                        await store.setVolume(Int(volumeValue.rounded()))
                    }
                }
            })
            .tint(Color(red: 0, green: 0.55, blue: 1))

            Button {
                Task {
                    await store.setMute(!(player?.muted ?? false))
                }
            } label: {
                Text(player?.muted == true ? "UNMUTE" : "MUTE")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.08))
                    .foregroundStyle(player?.muted == true ? Color(red: 0, green: 0.55, blue: 1) : Color.red)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(player?.muted == true ? Color(red: 0, green: 0.55, blue: 1).opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glossyGlassCard(cornerRadius: 12)
    }

    private func transportControls(_ player: PlayerState) -> some View {
        HStack(spacing: 24) {
            Button {
                Task {
                    await store.seek(to: max(0, player.percentage - 5))
                }
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(white: 0.8))
                    .frame(width: 50, height: 50)
                    .background(Color(white: 0.08))
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(white: 0.16), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    await store.playPause()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(red: 0, green: 0.55, blue: 1))
                        .frame(width: 74, height: 74)
                        .shadow(color: Color(red: 0, green: 0.55, blue: 1).opacity(0.4), radius: 6)
                    
                    Image(systemName: player.speed == 0 ? "play.fill" : "pause.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.black)
                        .offset(x: player.speed == 0 ? 2 : 0)
                }
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    await store.seek(to: min(100, player.percentage + 5))
                }
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(white: 0.8))
                    .frame(width: 50, height: 50)
                    .background(Color(white: 0.08))
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(white: 0.16), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    await store.stop()
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
                    .frame(width: 50, height: 50)
                    .background(Color(white: 0.08))
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.red.opacity(0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func channelControls(_ player: PlayerState) -> some View {
        let audioStreams = player.audioStreams.filter { $0.index != nil }
        
        HStack(spacing: 12) {
            if !audioStreams.isEmpty {
                Menu {
                    ForEach(audioStreams, id: \.id) { stream in
                        if let index = stream.index {
                            Button {
                                Task { await store.setAudio(index: index) }
                            } label: {
                                Text(audioStreamLabel(stream))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                        Text("Audio")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color(white: 0.8))
                    .glossyGlassCard(cornerRadius: 10)
                }
            }

            Menu {
                Button("Disable Subtitles") {
                    Task { await store.setSubtitle(index: nil) }
                }
                ForEach(player.subtitles.filter { $0.index != nil }, id: \.id) { subtitle in
                    if let index = subtitle.index {
                        Button {
                            Task { await store.setSubtitle(index: index) }
                        } label: {
                            Text(subtitleStreamLabel(subtitle))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "captions.bubble")
                    Text("Subtitles")
                }
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(Color(white: 0.8))
                .glossyGlassCard(cornerRadius: 10)
            }

            Button {
                showSyncSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("Sync")
                }
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(Color(white: 0.8))
                .glossyGlassCard(cornerRadius: 10)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    private func syncControls() {
        seekValue = store.player?.percentage ?? 0
        volumeValue = Double(store.player?.volume ?? 50)
    }
}

struct DelayControlRow: View {
    let title: String
    let value: String
    let onMinus: () -> Void
    let onReset: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.6))

            Spacer()

            HStack(spacing: 8) {
                Button(action: onMinus) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(white: 0.8))
                        .frame(width: 32, height: 32)
                        .background(Color(white: 0.12))
                        .clipShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button(action: onReset) {
                    Text(value)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                        .frame(minWidth: 54)
                        .padding(.vertical, 6)
                        .background(Color(white: 0.04))
                        .clipShape(.rect(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(white: 0.16), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onPlus) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(white: 0.8))
                        .frame(width: 32, height: 32)
                        .background(Color(white: 0.12))
                        .clipShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
