import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
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
                #if os(iOS)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                #endif
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
                    .background(Color.interlaceAccent)
                    .foregroundStyle(.black)
                    .clipShape(.rect(cornerRadius: 8))
                }
                .disabled(store.isAddingDownload)
                .buttonStyle(.plain)
                .accessibilityLabel("Add URL download")

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
                .accessibilityLabel("Import torrent file")
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

struct DownloadRow: View, Equatable {
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
                                .foregroundStyle(Color.interlaceAccent)
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
                    .foregroundStyle(Color.interlaceAccent)
            }

            // Neo progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.05))
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.interlaceAccent)
                        .frame(width: max(0, CGFloat(progressValue) * geo.size.width))
                        .shadow(color: Color.interlaceAccent.opacity(0.4), radius: 2)
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
                        .accessibilityLabel("Pause download")
                    }

                    if canResume {
                        Button {
                            onResume()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.interlaceAccent)
                                .frame(width: 32, height: 26)
                                .background(Color(white: 0.12))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Resume download")
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
                    .accessibilityLabel("Remove download")
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
