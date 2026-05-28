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
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = InterlaceStore()
    @State private var autoConnectAttemptedBaseURL: String?

    var body: some View {
        Group {
            if store.isConnected {
                ConnectedRootView(store: store, savedBaseURL: $savedBaseURL)
            } else if shouldShowStoredConnectionProgress {
                StoredConnectionProgressView(serverURL: savedBaseURL)
            } else {
                LoginView(store: store, savedBaseURL: $savedBaseURL)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.configureSavedBaseURL(savedBaseURL)
        }
        .task(id: savedBaseURL) {
            await connectToSavedServerIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                store.resumeBackgroundPolling()
            case .background, .inactive:
                store.suspendBackgroundPolling()
            @unknown default:
                break
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

    private var hasSavedBaseURL: Bool {
        !trimmedSavedBaseURL.isEmpty
    }

    private var trimmedSavedBaseURL: String {
        savedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowStoredConnectionProgress: Bool {
        hasSavedBaseURL && (store.isConnecting || autoConnectAttemptedBaseURL != trimmedSavedBaseURL)
    }

    private func connectToSavedServerIfNeeded() async {
        let trimmedBaseURL = trimmedSavedBaseURL
        guard !trimmedBaseURL.isEmpty else { return }
        if store.isConnected {
            autoConnectAttemptedBaseURL = trimmedBaseURL
            return
        }
        guard autoConnectAttemptedBaseURL != trimmedBaseURL else { return }
        guard !store.isConnecting else { return }

        autoConnectAttemptedBaseURL = trimmedBaseURL
        store.configureSavedBaseURL(trimmedBaseURL)
        await store.connect()
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
            .accessibilityHidden(true)
    }
}

struct VideoThumbnailView: View {
    let videoURL: URL
    @State private var thumbnailImage: UIImage? = nil
    @State private var isLoading = false
    @State private var isBreathing = false
    
    var body: some View {
        ZStack {
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transition(.opacity)
            } else {
                ZStack {
                    Color(white: 0.04)
                    
                    Image(systemName: "film")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(white: 0.15))
                        .scaleEffect(isBreathing ? 1.05 : 0.95)
                        .opacity(isBreathing ? 0.6 : 0.2)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        isBreathing = true
                    }
                }
            }
        }
        .animation(.easeIn(duration: 0.25), value: thumbnailImage)
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
    case player = "Player"
    case downloads = "Downloads"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .library: return "film"
        case .player: return "play.rectangle"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Root Dashboard Container (Floating Tabs System)

private struct ConnectedRootView: View {
    let store: InterlaceStore
    @Binding var savedBaseURL: String
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
                    case .player:
                        NavigationStack {
                            PlayerView(store: store)
                        }
                    case .downloads:
                        NavigationStack {
                            DownloadsView(store: store)
                        }
                    case .settings:
                        NavigationStack {
                            SettingsView(store: store, savedBaseURL: $savedBaseURL)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer()
                    .frame(height: 58)
            }

            // Demo mode indicator
            if store.isDemoMode {
                VStack {
                    HStack {
                        Spacer()
                        Text("DEMO")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.interlaceAccent)
                            .clipShape(.capsule)
                            .padding(.trailing, 16)
                            .padding(.top, 8)
                    }
                    Spacer()
                }
                .accessibilityHidden(true)
            }

            // Custom floating Liquid Glass Tab Bar
            AdaptiveGlassEffectContainer {
                LiquidGlassTabBar(selectedTab: $selectedTab)
                    .frame(maxWidth: 560)
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
                                        .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
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
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .liquidGlassCapsule {
            Color.clear
        }
    }
}

private struct StoredConnectionProgressView: View {
    let serverURL: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)

                ProgressView()
                    .tint(.white)

                Text(serverURL)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.6))
                    .lineLimit(1)
                    .padding(.horizontal, 28)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Utility Formatting Functions

func audioStreamLabel(_ stream: MediaStream) -> String {
    let language = stream.language?.isEmpty == false ? stream.language! : "?"
    let name = stream.name?.isEmpty == false ? stream.name! : "Track \(stream.index ?? 0)"
    if let codec = stream.codec, !codec.isEmpty {
        return "\(language) - \(name) (\(codec))"
    }
    return "\(language) - \(name)"
}

func videoStreamLabel(_ stream: MediaStream) -> String {
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

func subtitleStreamLabel(_ stream: MediaStream) -> String {
    let language = stream.language?.isEmpty == false ? stream.language! : "?"
    let name = stream.name?.isEmpty == false ? stream.name! : "Subtitle \(stream.index ?? 0)"
    return "\(language) - \(name)"
}

func formatDelayEstimate(_ steps: Int) -> String {
    String(format: "%+.1fs", Double(steps) * 0.1)
}

func formatUptime(_ seconds: Int) -> String {
    let d = seconds / 86400
    let h = (seconds % 86400) / 3600
    let m = (seconds % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatSpeed(_ bytesPerSecond: Int64) -> String {
    "\(formatBytes(bytesPerSecond))/s"
}

func formatDuration(_ seconds: Double) -> String {
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

extension Color {
    static let interlaceAccent = Color(red: 0, green: 0.55, blue: 1)
    static let interlaceAccentWarm = Color(red: 0.9, green: 0.5, blue: 0)
}

extension View {
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
                    
                    Color.interlaceAccent.opacity(0.02)
                    
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
    func interlaceReadableWidth(_ maxWidth: CGFloat = 560) -> some View {
        self
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }

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
