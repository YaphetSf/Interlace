//
//  ContentView.swift
//  Interlace-Remote
//
//  Created by Ding Zhong on 27/05/2026.
//

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Observation
import UIKit

struct ContentView: View {
    @AppStorage("interlace.baseURL") private var savedBaseURL = ""
    @State private var store = InterlaceStore()

    var body: some View {
        Group {
            if store.isConnected {
                ConnectedRootView(store: store)
            } else {
                ConnectionView(store: store, savedBaseURL: $savedBaseURL)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.configureSavedBaseURL(savedBaseURL)
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
}

// MARK: - Reusable Cyber Visual Nodes

struct LEDIndicatorView: View {
    let color: Color
    @State private var breathing = false
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.8), radius: breathing ? 4 : 1)
            .opacity(breathing ? 1.0 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

struct VideoThumbnailView: View {
    let videoURL: URL
    @State private var thumbnailImage: UIImage? = nil
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Color(white: 0.04)
                
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(white: 0.3))
                }
            }
        }
        .task(id: videoURL) {
            await loadThumbnail()
        }
    }
    
    private func loadThumbnail() async {
        if let cached = VideoThumbnailPipeline.shared.cachedImage(for: videoURL) {
            thumbnailImage = cached
            isLoading = false
            return
        }

        guard thumbnailImage == nil, !VideoThumbnailPipeline.shared.hasFailed(videoURL) else { return }
        isLoading = true
        defer { isLoading = false }

        thumbnailImage = await VideoThumbnailPipeline.shared.image(for: videoURL)
    }
}

private final class VideoThumbnailPipeline {
    static let shared = VideoThumbnailPipeline()

    private let cache = NSCache<NSURL, UIImage>()
    private let failures = NSCache<NSURL, NSNumber>()
    private let limiter = AsyncSemaphore(value: 2)

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 24 * 1024 * 1024
        failures.countLimit = 300
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func hasFailed(_ url: URL) -> Bool {
        failures.object(forKey: url as NSURL) != nil
    }

    func image(for url: URL) async -> UIImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if failures.object(forKey: key) != nil {
            return nil
        }

        await limiter.wait()
        do {
            try Task.checkCancellation()

            if let cached = cache.object(forKey: key) {
                await limiter.signal()
                return cached
            }
            if failures.object(forKey: key) != nil {
                await limiter.signal()
                return nil
            }

            guard let image = try await Self.generateThumbnail(for: url) else {
                failures.setObject(1, forKey: key)
                await limiter.signal()
                return nil
            }

            cache.setObject(image, forKey: key, cost: image.cacheCost)
            await limiter.signal()
            return image
        } catch is CancellationError {
            await limiter.signal()
            return nil
        } catch {
            failures.setObject(1, forKey: key)
            await limiter.signal()
            return nil
        }
    }

    private static func generateThumbnail(for url: URL) async throws -> UIImage? {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)

        let time = CMTime(seconds: 15, preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(at: time)
            return UIImage(cgImage: cgImage)
        } catch {
            let fallbackTime = CMTime(seconds: 1, preferredTimescale: 600)
            let (cgImage, _) = try await generator.image(at: fallbackTime)
            return UIImage(cgImage: cgImage)
        }
    }
}

private actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = value
    }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private extension UIImage {
    var cacheCost: Int {
        Int(size.width * scale) * Int(size.height * scale) * 4
    }
}

enum InterlaceTab: String, CaseIterable {
    case library = "Library"
    case downloads = "Downloads"
    case player = "Player"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .library: return "film"
        case .downloads: return "arrow.down.circle"
        case .player: return "play.rectangle"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Root Dashboard Container (Floating Tabs System)

private struct ConnectedRootView: View {
    let store: InterlaceStore
    @State private var selectedTab: InterlaceTab = .library
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .library:
                        NavigationStack {
                            LibraryView(store: store)
                        }
                    case .downloads:
                        NavigationStack {
                            DownloadsView(store: store)
                        }
                    case .player:
                        NavigationStack {
                            PlayerView(store: store)
                        }
                    case .settings:
                        NavigationStack {
                            SettingsView(store: store)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer()
                    .frame(height: 58)
            }

            // Custom floating Liquid Glass Tab Bar
            AdaptiveGlassEffectContainer {
                LiquidGlassTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 0)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

struct LiquidGlassTabBar: View {
    @Binding var selectedTab: InterlaceTab
    @Namespace private var tabNamespace
    @State private var shimmer = false
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(InterlaceTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                        selectedTab = tab
                    }
                } label: {
                    ZStack {
                        if isSelected {
                            // Custom floating Liquid Glass active highlight bubble (frosted crystal, no glow)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.12),
                                            Color.white.opacity(0.02)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 68, height: 48)
                                .overlay(
                                    Capsule()
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.35),
                                                    Color.white.opacity(0.08)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 1.0
                                        )
                                        .shadow(color: Color.black.opacity(0.2), radius: shimmer ? 3 : 2, x: 0, y: 1)
                                )
                                .matchedGeometryEffect(id: "liquidBubble", in: tabNamespace)
                        } else {
                            Capsule()
                                .fill(Color.clear)
                                .frame(width: 68, height: 48)
                        }
                        
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18, weight: isSelected ? .bold : .regular))
                                .foregroundStyle(isSelected ? .white : Color(white: 0.45))
                                .scaleEffect(isSelected ? 1.15 : 1.0)
                            Text(tab.rawValue)
                                .font(.system(size: 9, weight: isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? .white : Color(white: 0.4))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .liquidGlassCapsule {
            Color.clear
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
    }
}

// MARK: - Server Connection Screen (Onboarding)

private struct ConnectionView: View {
    @Bindable var store: InterlaceStore
    @Binding var savedBaseURL: String
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 40) {
                    Spacer()
                    
                    // Centered glowing rack module
                    ZStack {
                        Circle()
                            .stroke(Color(red: 0, green: 0.55, blue: 1).opacity(0.12), lineWidth: 2)
                            .frame(width: 110, height: 110)
                        Image(systemName: "server.rack")
                            .font(.system(size: 40))
                            .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                            .shadow(color: Color(red: 0, green: 0.55, blue: 1), radius: 6)
                    }
                    
                    // Simple matte card with no examples or paragraphs
                    VStack(spacing: 20) {
                        TextField("interlace.local:8000", text: $store.baseURLText)
                            .interlaceURLTextInput()
                            .font(.system(size: 14, design: .monospaced))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(Color(white: 0.05))
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isFieldFocused ? Color(red: 0, green: 0.55, blue: 1) : Color(white: 0.15), lineWidth: 1)
                                    .shadow(color: isFieldFocused ? Color(red: 0, green: 0.55, blue: 1).opacity(0.3) : .clear, radius: 4)
                            )
                            .focused($isFieldFocused)
                            .onSubmit {
                                connect()
                            }
                        
                        Button {
                            connect()
                        } label: {
                            HStack {
                                if store.isConnecting {
                                    ProgressView()
                                        .tint(.black)
                                } else {
                                    Image(systemName: "chevron.right.circle.fill")
                                        .font(.system(size: 16))
                                }
                                Text(store.isConnecting ? "CONNECTING..." : "CONNECT")
                                    .font(.system(size: 13, weight: .bold))
                                    .tracking(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0, green: 0.55, blue: 1))
                            .foregroundStyle(.black)
                            .clipShape(.rect(cornerRadius: 12))
                            .shadow(color: Color(red: 0, green: 0.55, blue: 1).opacity(0.3), radius: 6)
                        }
                        .disabled(store.isConnecting)
                    }
                    .padding(24)
                    .liquidGlass(cornerRadius: 20)
                    .padding(.horizontal, 24)
                    
                    Spacer()
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
    }

    private func connect() {
        Task {
            let connected = await store.connect()
            if connected {
                savedBaseURL = store.baseURLText
            }
        }
    }
}

// MARK: - Settings Tab Screen

private struct SettingsView: View {
    let store: InterlaceStore

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Server info card
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 20))
                                .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                                .frame(width: 44, height: 44)
                                .background(Color(white: 0.08))
                                .clipShape(.rect(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color(white: 0.16), lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.connectedURLLabel)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.8))
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    LEDIndicatorView(color: store.isConnected ? .green : .red)
                                    Text(store.statusLabel)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color(white: 0.5))
                                        .tracking(0.5)
                                }
                            }

                            Spacer()

                            if store.isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                        }

                        Divider()
                            .background(Color(white: 0.12))

                        // Actions
                        HStack(spacing: 12) {
                            Button {
                                Task { await store.refreshAll() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("Refresh")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .foregroundStyle(Color(white: 0.8))
                                .background(Color(white: 0.08))
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(white: 0.16), lineWidth: 1)
                                )
                            }
                            .disabled(store.isRefreshing)
                            .buttonStyle(.plain)

                            Button {
                                store.disconnect()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "power")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("Disconnect")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .foregroundStyle(.red)
                                .background(Color(white: 0.08))
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .glossyGlassCard(cornerRadius: 16)

                    // Status info
                    if let status = store.status {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SERVER INFO")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(white: 0.4))
                                .tracking(1)

                            if let version = status.version {
                                statusRow(label: "Version", value: version)
                            }
                            if let message = status.message, !message.isEmpty {
                                statusRow(label: "Message", value: message)
                            }
                        }
                        .padding(16)
                        .glossyGlassCard(cornerRadius: 16)
                    }

                    // Disk usage
                    if let disk = store.disk {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("STORAGE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(white: 0.4))
                                .tracking(1)

                            DiskRow(disk: disk)
                                .padding(.horizontal, 0)

                            HStack {
                                Text(formatBytes(disk.used))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.6))
                                Text("used of")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(white: 0.4))
                                Text(formatBytes(disk.total))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.6))
                                Spacer()
                                Text("\(Int(disk.percent))%")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(disk.percent > 90 ? .red : disk.percent > 75 ? .orange : .green)
                            }
                        }
                        .padding(16)
                        .glossyGlassCard(cornerRadius: 16)
                    }

                    // System stats
                    if let sys = store.systemInfo {
                        SystemStatsCard(sys: sys)
                    }
                }
                .padding(16)
                Spacer()
                    .frame(height: 40)
            }
            .refreshable {
                await store.refreshAll()
            }
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.8))
        }
    }
}

// MARK: - Downloads Tab Screen

private struct DownloadsView: View {
    let store: InterlaceStore
    @State private var uri = ""
    @State private var isImportingTorrent = false

    private var torrentContentTypes: [UTType] {
        [UTType(filenameExtension: "torrent") ?? .data]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                addDownloadBar
                
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if store.downloads.isEmpty {
                            VStack(spacing: 16) {
                                Spacer()
                                    .frame(height: 80)
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 40))
                                    .foregroundStyle(Color(white: 0.25))
                            }
                        } else {
                            ForEach(store.downloads) { download in
                                DownloadRow(
                                    download: download,
                                    onPause: { Task { await store.pause(download) } },
                                    onResume: { Task { await store.resume(download) } },
                                    onRemove: { Task { await store.remove(download) } }
                                )
                                .equatable()
                            }
                        }
                    }
                    .padding(16)
                    Spacer()
                        .frame(height: 40)
                }
                .refreshable {
                    await store.refreshDownloads()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await store.refreshDownloads()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingTorrent,
            allowedContentTypes: torrentContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await store.addTorrent(fileURL: url)
                }
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private var addDownloadBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Add URL...", text: $uri)
                    .interlaceURLTextInput()
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.05))
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(white: 0.18), lineWidth: 1)
                    )

                Button {
                    addURI()
                } label: {
                    ZStack {
                        if store.isAddingDownload {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(Color(red: 0, green: 0.55, blue: 1))
                    .foregroundStyle(.black)
                    .clipShape(.rect(cornerRadius: 8))
                }
                .disabled(store.isAddingDownload)
                .buttonStyle(.plain)

                Button {
                    isImportingTorrent = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(white: 0.8))
                        .frame(width: 36, height: 36)
                        .background(Color(white: 0.08))
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(white: 0.18), lineWidth: 1)
                        )
                }
                .disabled(store.isAddingDownload)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)
            
            Divider()
                .background(Color(white: 0.16))
        }
    }

    private func addURI() {
        Task {
            let added = await store.addURI(uri)
            if added {
                uri = ""
            }
        }
    }
}

private struct DownloadRow: View, Equatable {
    let download: DownloadItem
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void

    static func == (lhs: DownloadRow, rhs: DownloadRow) -> Bool {
        lhs.download == rhs.download
    }

    private var progressValue: Double {
        min(max(download.progress / 100, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: download.isTorrent ? "arrow.down.doc.fill" : "link.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(statusColor)
                    .frame(width: 24, height: 24)
                    .background(Color(white: 0.05))
                    .clipShape(.rect(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(download.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        LEDIndicatorView(color: statusColor)
                        
                        if download.speed > 0 {
                            Text(formatSpeed(download.speed))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                            Text("•")
                                .foregroundStyle(Color(white: 0.25))
                        }
                        
                        Text("\(formatBytes(download.completed)) / \(formatBytes(download.total))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(white: 0.45))
                    }
                }

                Spacer()

                Text("\(Int(download.progress.rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
            }

            // Neo progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.05))
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: 0, green: 0.55, blue: 1))
                        .frame(width: max(0, CGFloat(progressValue) * geo.size.width))
                        .shadow(color: Color(red: 0, green: 0.55, blue: 1).opacity(0.4), radius: 2)
                }
            }
            .frame(height: 4)

            // Dynamic mini pill controls
            HStack {
                Spacer()

                HStack(spacing: 8) {
                    if canPause {
                        Button {
                            onPause()
                        } label: {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(white: 0.7))
                                .frame(width: 32, height: 26)
                                .background(Color(white: 0.12))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    if canResume {
                        Button {
                            onResume()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                                .frame(width: 32, height: 26)
                                .background(Color(white: 0.12))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .frame(width: 32, height: 26)
                            .background(Color(white: 0.12))
                            .clipShape(.rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .glossyGlassCard(cornerRadius: 16)
    }

    private var canPause: Bool {
        ["active", "waiting"].contains(download.status.lowercased())
    }

    private var canResume: Bool {
        download.status.lowercased() == "paused"
    }

    private var statusColor: Color {
        switch download.status.lowercased() {
        case "active":
            return .green
        case "waiting":
            return .orange
        case "paused":
            return .blue
        case "complete":
            return .white
        case "error":
            return .red
        default:
            return Color(white: 0.4)
        }
    }
}

// MARK: - Library Tab Screen

private struct LibraryView: View {
    let store: InterlaceStore
    @State private var isImportingSubtitle = false
    @State private var subtitleTarget: LibraryItem?
    @State private var searchQuery = ""

    private var subtitleContentTypes: [UTType] {
        [
            UTType(filenameExtension: "srt"),
            UTType(filenameExtension: "ass"),
            UTType(filenameExtension: "vtt"),
            .text
        ].compactMap { $0 }
    }

    private var filteredItems: [LibraryItem] {
        if searchQuery.isEmpty {
            return store.library
        }
        return store.library.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 155, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top Search Bar
                searchBar
                
                ScrollView {
                    LazyVStack(spacing: 16) {
                        // Breadcrumbs & micro back arrow
                        LibraryPathRow(
                            libraryPath: store.libraryPath,
                            onRoot: { Task { await store.goToLibraryPath("") } },
                            onPath: { path in Task { await store.goToLibraryPath(path) } },
                            onUp: { Task { await store.goUpLibrary() } }
                        )
                        .equatable()
                        
                        if !store.uploads.isEmpty {
                            UploadsInlineView(uploads: store.uploads)
                        }
                        
                        // Media Content Grid
                        if store.isLoadingLibrary {
                            VStack(spacing: 16) {
                                Spacer()
                                    .frame(height: 60)
                                ProgressView()
                                    .tint(.white)
                            }
                        } else if filteredItems.isEmpty {
                            VStack(spacing: 16) {
                                Spacer()
                                    .frame(height: 60)
                                Image(systemName: searchQuery.isEmpty ? "film.stack" : "magnifyingglass")
                                    .font(.system(size: 32))
                                    .foregroundStyle(Color(white: 0.25))
                            }
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(filteredItems) { item in
                                    LibraryCard(
                                        item: item,
                                        baseURLText: store.baseURLText,
                                        onOpenDirectory: { Task { await store.openDirectory(item) } },
                                        onPlay: { Task { await store.play(item) } },
                                        onDelete: { Task { await store.deleteLibraryItem(item) } },
                                        onUploadSubtitle: {
                                            subtitleTarget = item
                                            isImportingSubtitle = true
                                        }
                                    )
                                    .equatable()
                                }
                            }
                        }
                    }
                    .padding(16)
                    Spacer()
                        .frame(height: 40)
                }
                .refreshable {
                    await store.refreshLibrary()
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingSubtitle,
            allowedContentTypes: subtitleContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let target = subtitleTarget, let url = urls.first else { return }
                Task {
                    await store.uploadSubtitle(for: target, fileURL: url)
                }
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
            subtitleTarget = nil
        }
    }

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.4))
                
                TextField("Search library items...", text: $searchQuery)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(white: 0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(white: 0.05))
            .clipShape(.rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(white: 0.16), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)
            
            Divider()
                .background(Color(white: 0.16))
        }
    }
}

private struct LibraryPathRow: View, Equatable {
    let libraryPath: String
    let onRoot: () -> Void
    let onPath: (String) -> Void
    let onUp: () -> Void

    static func == (lhs: LibraryPathRow, rhs: LibraryPathRow) -> Bool {
        lhs.libraryPath == rhs.libraryPath
    }

    private var pathParts: [String] {
        libraryPath.split(separator: "/").map(String.init)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Back Arrow micro pill button
            if !libraryPath.isEmpty {
                Button {
                    onUp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                        .frame(width: 28, height: 28)
                        .background(Color(white: 0.08))
                        .clipShape(.rect(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(white: 0.16), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        onRoot()
                    } label: {
                        Text("Downloads")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.08))
                            .foregroundStyle(Color(white: 0.8))
                            .clipShape(.rect(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(white: 0.16), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    ForEach(Array(pathParts.enumerated()), id: \.offset) { index, part in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(white: 0.3))

                        Button {
                            let path = pathParts.prefix(index + 1).joined(separator: "/")
                            onPath(path)
                        } label: {
                            Text(part)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(white: 0.08))
                                .foregroundStyle(Color(white: 0.8))
                                .clipShape(.rect(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(white: 0.16), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct LibraryCard: View, Equatable {
    let item: LibraryItem
    let baseURLText: String
    let onOpenDirectory: () -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onUploadSubtitle: () -> Void

    static func == (lhs: LibraryCard, rhs: LibraryCard) -> Bool {
        lhs.item == rhs.item && lhs.baseURLText == rhs.baseURLText
    }

    private func videoURL(for item: LibraryItem) -> URL? {
        let base = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        
        var candidate = base
        if !candidate.contains("://") {
            candidate = "http://\(candidate)"
        }
        
        guard var components = URLComponents(string: candidate) else { return nil }
        components.query = nil
        
        let cleanedRel = item.rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/videos/\(cleanedRel)"
        
        return components.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if item.isDirectory {
                // Folder Card
                Button {
                    onOpenDirectory()
                } label: {
                    VStack(spacing: 12) {
                        Spacer(minLength: 0)
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(red: 0, green: 0.45, blue: 0.9).opacity(0.1))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: "folder.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                                .shadow(color: Color(red: 0, green: 0.55, blue: 1).opacity(0.4), radius: 3)
                        }
                        
                        Text(item.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 175)
                    .glossyGlassCard(cornerRadius: 16)
                }
                .buttonStyle(.plain)
            } else {
                // File Card
                VStack(alignment: .leading, spacing: 0) {
                    // Visual Upper Half (Dynamic Remote Video Thumbnail)
                    ZStack {
                        if let vURL = videoURL(for: item) {
                            VideoThumbnailView(videoURL: vURL)
                                .clipShape(.rect(cornerRadius: 10))
                        } else {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(white: 0.04))
                            
                            Image(systemName: "film")
                                .font(.system(size: 20))
                                .foregroundStyle(Color(white: 0.3))
                        }
                        
                        if item.size > 0 {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Text(formatBytes(item.size))
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color(white: 0.6))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(.rect(cornerRadius: 4))
                                }
                                .padding(6)
                            }
                        }
                    }
                    .frame(height: 70)
                    .padding(.bottom, 8)
                    
                    // Title
                    Text(item.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                    
                    Spacer(minLength: 0)
                    
                    // Compact control deck (NO TEXT! Pure symbol micro keys)
                    HStack(spacing: 8) {
                        Button {
                            onPlay()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color(red: 0, green: 0.55, blue: 1))
                                .clipShape(.rect(cornerRadius: 6))
                                .shadow(color: Color(red: 0, green: 0.55, blue: 1).opacity(0.3), radius: 3)
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            onUploadSubtitle()
                        } label: {
                            Image(systemName: "captions.bubble.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(white: 0.8))
                                .frame(width: 28, height: 24)
                                .background(Color(white: 0.12))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .frame(width: 28, height: 24)
                                .background(Color(white: 0.12))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .frame(height: 175)
                .glossyGlassCard(cornerRadius: 16)
            }
        }
    }
}

private struct UploadsInlineView: View {
    let uploads: [UploadTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(uploads) { upload in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: upload.status))
                        .font(.system(size: 11))
                        .foregroundStyle(color(for: upload.status))

                    Text(upload.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer()
                    
                    Text("\(Int(upload.progress))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(color(for: upload.status))
                }
                .padding(10)
                .background(Color(white: 0.08))
                .clipShape(.rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(white: 0.14), lineWidth: 1)
                )
            }
        }
    }

    private func iconName(for status: UploadTaskStatus) -> String {
        switch status {
        case .uploading:
            return "arrow.up.circle.fill"
        case .done:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: UploadTaskStatus) -> Color {
        switch status {
        case .uploading:
            return Color(red: 0, green: 0.55, blue: 1)
        case .done:
            return .green
        case .error:
            return .red
        }
    }
}

private struct SystemStatsCard: View {
    let sys: SystemInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SYSTEM")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(white: 0.4))
                .tracking(1)

            // CPU
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.5))
                    Text("CPU")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.5))
                    Spacer()
                    if let temp = sys.cpuTemp {
                        HStack(spacing: 3) {
                            Image(systemName: "thermometer.medium")
                                .font(.system(size: 10))
                                .foregroundStyle(tempColor(temp))
                            Text(String(format: "%.0f°C", temp))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(tempColor(temp))
                        }
                        Text("·")
                            .foregroundStyle(Color(white: 0.25))
                    }
                    Text(String(format: "%.1f%%", sys.cpuPercent))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(usageColor(sys.cpuPercent))
                }
                StatBar(percent: sys.cpuPercent, color: usageColor(sys.cpuPercent))
            }

            // Memory
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.5))
                    Text("RAM")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.5))
                    Spacer()
                    Text(formatBytes(sys.memUsed))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.6))
                    Text("/")
                        .foregroundStyle(Color(white: 0.3))
                        .font(.system(size: 11))
                    Text(formatBytes(sys.memTotal))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.6))
                    Text("·")
                        .foregroundStyle(Color(white: 0.25))
                    Text(String(format: "%.0f%%", sys.memPercent))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(usageColor(sys.memPercent))
                }
                StatBar(percent: sys.memPercent, color: usageColor(sys.memPercent))
            }

            Divider()
                .background(Color(white: 0.1))

            // Network
            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                    Text(formatSpeed(sys.downloadSpeed))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.7))
                }
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.9, green: 0.5, blue: 0))
                    Text(formatSpeed(sys.uploadSpeed))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.7))
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.4))
                    Text(formatUptime(sys.uptime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(white: 0.5))
                }
            }
        }
        .padding(16)
        .glossyGlassCard(cornerRadius: 16)
    }

    private func usageColor(_ percent: Double) -> Color {
        percent > 90 ? .red : percent > 70 ? .orange : .green
    }

    private func tempColor(_ temp: Double) -> Color {
        temp > 85 ? .red : temp > 70 ? .orange : Color(white: 0.6)
    }
}

private struct StatBar: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.05))
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(0, CGFloat(percent / 100) * geo.size.width))
                    .shadow(color: color.opacity(0.4), radius: 2)
            }
        }
        .frame(height: 3)
    }
}

private struct DiskRow: View {
    let disk: DiskInfo

    var body: some View {
        // Segmented health bar. Silent diagnostic indicator with no text descriptions.
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.05))
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(disk.percent > 90 ? Color.red : (disk.percent > 75 ? Color.orange : Color.green))
                    .frame(width: max(0, CGFloat(disk.percent / 100) * geo.size.width))
                    .shadow(color: (disk.percent > 90 ? Color.red : (disk.percent > 75 ? Color.orange : Color.green)).opacity(0.4), radius: 2)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 4)
    }
}

// MARK: - Player Tab Screen (Tactile Command Console)

private struct PlayerView: View {
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
                            VStack(spacing: 24) {
                                Spacer()
                                    .frame(height: 60)
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: 48))
                                    .foregroundStyle(Color(white: 0.25))
                                
                                Spacer()
                                    .frame(height: 20)
                                
                                volumeControls(player)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await store.refreshPlayer()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                }
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

private struct DelayControlRow: View {
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

// MARK: - Utility Formatting Functions

private func audioStreamLabel(_ stream: MediaStream) -> String {
    let language = stream.language?.isEmpty == false ? stream.language! : "?"
    let name = stream.name?.isEmpty == false ? stream.name! : "Track \(stream.index ?? 0)"
    if let codec = stream.codec, !codec.isEmpty {
        return "\(language) - \(name) (\(codec))"
    }
    return "\(language) - \(name)"
}

private func videoStreamLabel(_ stream: MediaStream) -> String {
    let name = stream.name?.isEmpty == false ? stream.name! : "Stream \(stream.index ?? 0)"
    let dimensions: String
    if let width = stream.width, let height = stream.height, width > 0, height > 0 {
        dimensions = " \(width)x\(height)"
    } else {
        dimensions = ""
    }

    if let codec = stream.codec, !codec.isEmpty {
        return "\(name)\(dimensions) (\(codec))"
    }
    return "\(name)\(dimensions)"
}

private func subtitleStreamLabel(_ stream: MediaStream) -> String {
    let language = stream.language?.isEmpty == false ? stream.language! : "?"
    let name = stream.name?.isEmpty == false ? stream.name! : "Subtitle \(stream.index ?? 0)"
    return "\(language) - \(name)"
}

private func formatDelayEstimate(_ steps: Int) -> String {
    String(format: "%+.1fs", Double(steps) * 0.1)
}

private func formatUptime(_ seconds: Int) -> String {
    let d = seconds / 86400
    let h = (seconds % 86400) / 3600
    let m = (seconds % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

private func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func formatSpeed(_ bytesPerSecond: Int64) -> String {
    "\(formatBytes(bytesPerSecond))/s"
}

private func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }

    let totalSeconds = Int(seconds.rounded())
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

private extension View {
    @ViewBuilder
    func interlaceURLTextInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.go)
        #else
        self
        #endif
    }
}

// MARK: - Liquid Glass UI System (iOS 26+ Native + High-Fidelity Fallbacks)

#if os(iOS)
struct BackdropGlassView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        return view
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
#elseif os(macOS)
struct BackdropGlassView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#else
struct BackdropGlassView: View {
    var body: some View {
        Color.black.opacity(0.6)
    }
}
#endif

struct AdaptiveGlassEffectContainer<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    
    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if let spacing = spacing {
                GlassEffectContainer(spacing: spacing) {
                    content()
                }
            } else {
                GlassEffectContainer {
                    content()
                }
            }
        } else {
            content()
        }
    }
}

struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    var shadowRadius: CGFloat = 15
    var tintColor: Color = .clear
    var isInteractive: Bool = false
    
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tintColor).interactive(isInteractive),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(
                    ZStack {
                        BackdropGlassView()
                        
                        Color(red: 0.1, green: 0.12, blue: 0.16).opacity(tintColor == .clear ? 0.35 : 0.45)
                        if tintColor != .clear {
                            tintColor.opacity(0.15)
                        }
                        
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.35),
                                        Color.white.opacity(0.05),
                                        Color.black.opacity(0.4),
                                        Color.white.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                        
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.25), Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .blur(radius: 0.5)
                            .mask(
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: Color.black.opacity(0.55), radius: shadowRadius, x: 0, y: shadowRadius * 0.8)
                .shadow(color: Color.black.opacity(0.25), radius: shadowRadius / 3, x: 0, y: shadowRadius / 6)
        }
    }
}

struct LiquidGlassCapsuleModifier<Background: View>: ViewModifier {
    var tintColor: Color = .clear
    let backingGlow: Background
    
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .background(backingGlow)
                .glassEffect(
                    .regular.tint(tintColor),
                    in: .capsule
                )
        } else {
            content
                .background(
                    ZStack {
                        backingGlow
                        
                        BackdropGlassView()
                        
                        Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.5)
                        if tintColor != .clear {
                            tintColor.opacity(0.12)
                        }
                        
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.36),
                                        Color.white.opacity(0.04),
                                        Color.black.opacity(0.6),
                                        Color.white.opacity(0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.2
                            )
                        
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.25),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .blur(radius: 0.5)
                    }
                )
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.65), radius: 20, x: 0, y: 15)
                .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
        }
    }
}

struct GlossyGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.08), Color(white: 0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    
                    Color(red: 0, green: 0.55, blue: 1).opacity(0.02)
                    
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.02),
                                    Color.black.opacity(0.3)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 20, shadowRadius: CGFloat = 15, tintColor: Color = .clear, isInteractive: Bool = false) -> some View {
        self.modifier(LiquidGlassModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius, tintColor: tintColor, isInteractive: isInteractive))
    }
    
    func liquidGlassCapsule<B: View>(tintColor: Color = .clear, @ViewBuilder backingGlow: () -> B) -> some View {
        self.modifier(LiquidGlassCapsuleModifier(tintColor: tintColor, backingGlow: backingGlow()))
    }
    
    func glossyGlassCard(cornerRadius: CGFloat = 16) -> some View {
        self.modifier(GlossyGlassCardModifier(cornerRadius: cornerRadius))
    }
}
