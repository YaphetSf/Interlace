import SwiftUI
import Observation

struct SettingsView: View {
    @Bindable var store: InterlaceStore
    @Binding var savedBaseURL: String
    @State private var draftBaseURL = ""

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
                                Text("Interlace Server")
                                    .font(.system(size: 13, weight: .semibold))
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

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Server URL")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(white: 0.4))
                                .tracking(1)

                            HStack(spacing: 8) {
                                TextField("interlace.local:8000", text: $draftBaseURL)
                                    .interlaceURLTextInput()
                                    .font(.system(size: 13, design: .monospaced))
                                    .padding(.horizontal, 12)
                                    .frame(height: 40)
                                    .foregroundStyle(Color(white: 0.86))
                                    .background(Color(white: 0.05))
                                    .clipShape(.rect(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(white: 0.15), lineWidth: 1)
                                    )
                                    .onSubmit {
                                        applyServerURL()
                                    }

                                Button {
                                    applyServerURL()
                                } label: {
                                    Group {
                                        if store.isConnecting {
                                            ProgressView()
                                                .controlSize(.small)
                                                .tint(.black)
                                        } else {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .bold))
                                        }
                                    }
                                    .frame(width: 40, height: 40)
                                    .foregroundStyle(.black)
                                    .background(canApplyServerURL ? Color(red: 0, green: 0.55, blue: 1) : Color(white: 0.18))
                                    .clipShape(.rect(cornerRadius: 8))
                                }
                                .disabled(!canApplyServerURL)
                                .buttonStyle(.plain)
                                .accessibilityLabel("Apply server URL")
                            }
                        }

                        Divider()
                            .background(Color(white: 0.12))

                        // Actions
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
                }
                .padding(16)
                Spacer()
                    .frame(height: 40)
            }
            .refreshable {
                await store.refreshAll()
            }
        }
        .onAppear {
            draftBaseURL = savedBaseURL.isEmpty ? store.baseURLText : savedBaseURL
        }
        .onChange(of: savedBaseURL) { _, newValue in
            draftBaseURL = newValue
        }
    }

    private var appliedBaseURLText: String {
        savedBaseURL.isEmpty ? store.baseURLText : savedBaseURL
    }

    private var normalizedDraftBaseURLText: String? {
        guard let normalizedURL = try? InterlaceAPI.normalizedBaseURL(from: draftBaseURL) else {
            return nil
        }
        return InterlaceAPI.displayString(for: normalizedURL)
    }

    private var canApplyServerURL: Bool {
        guard !store.isConnecting, let normalizedDraftBaseURLText else { return false }
        return normalizedDraftBaseURLText != appliedBaseURLText
    }

    private func applyServerURL() {
        do {
            let normalizedURL = try InterlaceAPI.normalizedBaseURL(from: draftBaseURL)
            let normalizedText = InterlaceAPI.displayString(for: normalizedURL)
            draftBaseURL = normalizedText

            if store.isConnected {
                Task {
                    if await store.reconnect(to: normalizedText) {
                        savedBaseURL = store.baseURLText
                        draftBaseURL = store.baseURLText
                    }
                }
            } else {
                savedBaseURL = normalizedText
                store.baseURLText = normalizedText
            }
        } catch {
            store.errorMessage = error.localizedDescription
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

struct DiskRow: View {
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
