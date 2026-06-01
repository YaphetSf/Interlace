import SwiftUI

struct PlayerView: View {
    let store: InterlaceStore
    @State private var seekValue = 0.0
    @State private var isSeeking = false
    @State private var scrubSpeed = 1.0
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
                                
                                Text("Try playing something on your Interlace server to get started.")
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
                .interlaceReadableWidth()
                Spacer()
                    .frame(height: 40)
            }
            .refreshable {
                await store.refreshPlayer()
            }
            #if os(iOS)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            #endif
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
        // While scrubbing, the labels track where you're dragging to (derived
        // from seekValue) rather than the live playback position — so a long
        // movie gives real-time feedback about the target before you commit.
        let previewTime = isSeeking
            ? seekValue / 100 * player.totalTime
            : player.time

        return VStack(alignment: .leading, spacing: 8) {
            ScrubBar(
                value: $seekValue,
                onScrubbingChanged: { editing in
                    if editing {
                        isSeeking = true
                    } else {
                        // Capture the released value so a poll can't clobber it,
                        // and keep `isSeeking` true until the seek + refresh lands
                        // so the bar doesn't snap back to the live position.
                        let target = seekValue
                        Task {
                            await store.seek(to: target)
                            isSeeking = false
                        }
                    }
                },
                onSpeedChanged: { scrubSpeed = $0 }
            )

            HStack {
                Text(formatDuration(previewTime))
                Spacer()
                Text("-\(formatDuration(max(0, player.totalTime - previewTime)))")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(isSeeking ? Color.interlaceAccent : Color(white: 0.5))
            .overlay {
                if isSeeking && scrubSpeed < 1 {
                    Text(scrubSpeedLabel(scrubSpeed))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.interlaceAccent)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: scrubSpeed)
        }
    }

    private func scrubSpeedLabel(_ speed: Double) -> String {
        switch speed {
        case 0.5: return "½× SCRUB"
        case 0.25: return "¼× SCRUB"
        default: return "FINE SCRUB"
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
            .tint(Color.interlaceAccent)

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
                    .foregroundStyle(player?.muted == true ? Color.interlaceAccent : Color.red)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(player?.muted == true ? Color.interlaceAccent.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glossyGlassCard(cornerRadius: 12)
    }

    /// Converts an absolute playback time (seconds) into the 0...100 percentage
    /// the seek API expects, so the skip buttons move by real seconds.
    private func seekPercentage(forTime time: Double, in player: PlayerState) -> Double {
        guard player.totalTime > 0 else { return 0 }
        return (time / player.totalTime) * 100
    }

    private func transportControls(_ player: PlayerState) -> some View {
        HStack(spacing: 24) {
            Button {
                Task {
                    await store.seek(to: seekPercentage(forTime: max(0, player.time - 5), in: player))
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
            .accessibilityLabel("Skip back 5 seconds")
            .sensoryFeedback(.alignment, trigger: isSeeking)

            Button {
                Task {
                    await store.playPause()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.interlaceAccent)
                        .frame(width: 74, height: 74)
                        .shadow(color: Color.interlaceAccent.opacity(0.4), radius: 6)

                    Image(systemName: player.speed == 0 ? "play.fill" : "pause.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.black)
                        .offset(x: player.speed == 0 ? 2 : 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.speed == 0 ? "Play" : "Pause")
            .sensoryFeedback(.impact(weight: .medium), trigger: player.speed)

            Button {
                Task {
                    await store.seek(to: seekPercentage(forTime: min(player.totalTime, player.time + 5), in: player))
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
            .accessibilityLabel("Skip forward 5 seconds")

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
            .accessibilityLabel("Stop")
            .sensoryFeedback(.impact(weight: .light), trigger: player.active)
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

/// A seek bar with variable-speed scrubbing. Dragging horizontally moves the
/// playhead; moving the finger vertically away from the bar slows the scrub to
/// ½× / ¼× / fine, so even a multi-hour movie can be positioned to the second.
/// The position is applied incrementally (finger delta × current speed), which
/// is what decouples precision from the physical width of the bar.
struct ScrubBar: View {
    @Binding var value: Double          // 0...100
    var onScrubbingChanged: (Bool) -> Void
    var onSpeedChanged: (Double) -> Void = { _ in }

    @State private var isDragging = false
    @State private var lastTranslationWidth: CGFloat = 0

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 16
    private let hitHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usable = max(width - thumbSize, 1)
            let clamped = min(max(value, 0), 100)
            let thumbX = thumbSize / 2 + CGFloat(clamped / 100) * usable

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.16))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.interlaceAccent)
                    .frame(width: thumbX, height: trackHeight)

                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .scaleEffect(isDragging ? 1.3 : 1)
                    .offset(x: thumbX - thumbSize / 2)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
            }
            .frame(height: hitHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            lastTranslationWidth = 0
                            onScrubbingChanged(true)
                        }
                        let speed = scrubSpeed(forVerticalOffset: gesture.translation.height)
                        onSpeedChanged(speed)

                        let deltaW = gesture.translation.width - lastTranslationWidth
                        lastTranslationWidth = gesture.translation.width
                        let deltaValue = Double(deltaW / usable) * 100 * speed
                        value = min(max(value + deltaValue, 0), 100)
                    }
                    .onEnded { gesture in
                        // A near-stationary touch is a tap — jump straight there.
                        if abs(gesture.translation.width) < 4 && abs(gesture.translation.height) < 4 {
                            let x = gesture.location.x - thumbSize / 2
                            value = min(max(Double(x / usable) * 100, 0), 100)
                        }
                        isDragging = false
                        lastTranslationWidth = 0
                        onSpeedChanged(1)
                        onScrubbingChanged(false)
                    }
            )
        }
        .frame(height: hitHeight)
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue("\(Int(value.rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(100, value + 1)
            case .decrement: value = max(0, value - 1)
            default: break
            }
            onScrubbingChanged(false)
        }
    }

    /// Farther the finger drifts off the bar, the finer the control.
    private func scrubSpeed(forVerticalOffset dy: CGFloat) -> Double {
        switch abs(dy) {
        case ..<50: return 1.0
        case ..<100: return 0.5
        case ..<150: return 0.25
        default: return 0.1
        }
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
                        .foregroundStyle(Color.interlaceAccent)
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
