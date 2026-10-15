//
//  StreamView.swift
//  Interlace-Remote
//

import SwiftUI

struct StreamView: View {
    let store: InterlaceStore
    var onStreamStarted: () -> Void = {}

    @State private var url = ""
    @State private var quality: StreamQuality = .p1080
    @State private var result: StreamResponse?
    @FocusState private var urlFieldFocused: Bool

    private var canPlay: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isStreaming
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                card
                    .padding(16)
                    .interlaceReadableWidth()
                Spacer()
                    .frame(height: 40)
            }
            .scrollDismissesKeyboard(.interactively)
            #if os(iOS)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            #endif
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            inputSection
            if let result {
                resultBanner(result)
            }
            footnote
        }
        .padding(20)
        .glossyGlassCard(cornerRadius: 20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.interlaceAccent)
                .frame(width: 48, height: 48)
                .background(Color.interlaceAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.interlaceAccent.opacity(0.25), lineWidth: 1)
                )

            Text("Play an online video")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            Text("Paste a YouTube or other supported site URL, or a direct MP4, WebM, HLS, or DASH stream. Interlace resolves it and asks Kodi to play it without downloading the full video first.")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inputSection: some View {
        VStack(spacing: 12) {
            TextField("https://www.youtube.com/watch?v=...", text: $url)
                .interlaceURLTextInput()
                .focused($urlFieldFocused)
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(white: 0.04))
                .clipShape(.rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(urlFieldFocused ? Color.interlaceAccent.opacity(0.6) : Color(white: 0.16), lineWidth: 1)
                )
                .disabled(store.isStreaming)
                .onSubmit { startStream() }

            qualitySelector

            Button {
                startStream()
            } label: {
                ZStack {
                    if store.isStreaming {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Text("Play on Kodi")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(canPlay ? Color.interlaceAccent : Color(white: 0.15))
                .foregroundStyle(canPlay ? .black : Color(white: 0.4))
                .clipShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
        }
    }

    private var qualitySelector: some View {
        HStack(spacing: 8) {
            ForEach(StreamQuality.allCases, id: \.self) { option in
                let isSelected = quality == option
                Button {
                    quality = option
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(isSelected ? Color.interlaceAccent : Color(white: 0.5))
                        .background(isSelected ? Color.interlaceAccent.opacity(0.12) : Color(white: 0.04))
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.interlaceAccent.opacity(0.5) : Color(white: 0.14), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(store.isStreaming)
            }
        }
    }

    private func resultBanner(_ result: StreamResponse) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                if !result.title.isEmpty {
                    Text(result.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                Text(resultDetail(result))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.55))
            }
            Spacer()
        }
        .padding(12)
        .background(Color.green.opacity(0.08))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.2), lineWidth: 1)
        )
    }

    private var footnote: some View {
        Text("720p and 1080p use ffmpeg to combine separate video and audio streams without re-encoding. Compatible mode works without ffmpeg but may be limited to 360p. DRM-protected services are not supported.")
            .font(.system(size: 10))
            .foregroundStyle(Color(white: 0.35))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func resultDetail(_ result: StreamResponse) -> String {
        [result.quality, result.source]
            .filter { !$0.isEmpty }
            .joined(separator: " via ")
    }

    private func startStream() {
        guard canPlay else { return }
        urlFieldFocused = false
        Task {
            if let response = await store.stream(url: url, quality: quality) {
                result = response
                onStreamStarted()
            }
        }
    }
}
