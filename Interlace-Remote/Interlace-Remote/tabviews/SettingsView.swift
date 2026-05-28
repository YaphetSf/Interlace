import SwiftUI

struct SettingsView: View {
    let store: InterlaceStore
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
                                .foregroundStyle(Color.interlaceAccent)
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
                                    .background(canApplyServerURL ? Color.interlaceAccent : Color(white: 0.18))
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
                            Text("INFO")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(white: 0.4))
                                .tracking(1)

                            statusRow(label: "Server Ver", value: status.version ?? "Unknown")
                            
                            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                            let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                            statusRow(label: "App Ver", value: "\(appVersion) (\(appBuild))")
                        }
                        .padding(16)
                        .glossyGlassCard(cornerRadius: 16)
                    }

                    // System stats (CPU, RAM, Storage, Network, Uptime)
                    if store.systemInfo != nil || store.disk != nil {
                        SystemStatsCard(sys: store.systemInfo, disk: store.disk)
                    }
                }
                .padding(16)
                Spacer()
                    .frame(height: 40)
            }
            .refreshable {
                await store.refreshAll()
            }
            #if os(iOS)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            #endif
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

struct SystemStatsCard: View {
    let sys: SystemInfo?
    let disk: DiskInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SYSTEM")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(white: 0.4))
                .tracking(1)

            // CPU
            if let sys = sys {
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
            }

            // Storage
            if let disk = disk {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                        Text("Storage")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.5))
                        Spacer()
                        Text(formatBytes(disk.used))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(white: 0.6))
                        Text("/")
                            .foregroundStyle(Color(white: 0.3))
                            .font(.system(size: 11))
                        Text(formatBytes(disk.total))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(white: 0.6))
                        Text("·")
                            .foregroundStyle(Color(white: 0.25))
                        Text(String(format: "%.0f%%", disk.percent))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(usageColor(disk.percent))
                    }
                    StatBar(percent: disk.percent, color: usageColor(disk.percent))
                }
            }

            if let sys = sys {
                Divider()
                    .background(Color(white: 0.1))

                // Network
                HStack(spacing: 16) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.interlaceAccent)
                        Text(formatSpeed(sys.downloadSpeed))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(white: 0.7))
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.interlaceAccentWarm)
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

struct StatBar: View {
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
