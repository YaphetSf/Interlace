import SwiftUI

struct LibraryView: View {
    let store: WatchLibraryStore
    @Binding var savedBaseURL: String
    @Binding var usePhoneRelay: Bool
    @State private var showingNowPlaying = false

    var body: some View {
        NavigationStack {
            List {
                librarySection
                connectionSection
            }
            .navigationTitle("Library")
            .navigationDestination(isPresented: $showingNowPlaying) {
                PlayView(store: store)
            }
            .refreshable {
                await store.refreshLibrary()
            }
            .toolbar {
                if !store.libraryPath.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            Task { await store.goUp() }
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .accessibilityLabel("Go up one folder")
                    }
                }

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

    @ViewBuilder
    private var librarySection: some View {
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
                    libraryItemRow(item) {
                        Task {
                            await store.open(item)
                            // Files push Now Playing; folders navigate in place.
                            if !item.isDirectory {
                                showingNowPlaying = true
                            }
                        }
                    }
                }
            }
        }
    }

    private var connectionSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: store.usingPhoneRelay ? "iphone" : "wifi")
                    .font(.system(size: 14))
                    .foregroundStyle(store.usingPhoneRelay ? .blue : .green)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(store.usingPhoneRelay ? "Connected via iPhone" : "Connected via LAN")
                        .font(.caption.weight(.semibold))
                    if !store.usingPhoneRelay, !store.connectionLabel.isEmpty {
                        Text(store.connectionLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Button(role: .destructive) {
                savedBaseURL = ""
                usePhoneRelay = false
                store.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
    }

    private func libraryItemRow(_ item: WatchLibraryItem, action: @escaping () -> Void) -> some View {
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
                        Text(formatBytes(item.size))
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

    private func formatBytes(_ bytes: Int64) -> String {
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
}
