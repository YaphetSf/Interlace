import SwiftUI

// MARK: - Login Screen

private enum ConnectionMode: String, CaseIterable {
    case lan, tailscale, `public`

    var label: String {
        switch self {
        case .lan: "LAN"
        case .tailscale: "Tailscale"
        case .public: "Public"
        }
    }

    var autoPrefix: String {
        switch self {
        case .lan: "192.168."
        case .tailscale: "100."
        case .public: ""
        }
    }

    var placeholder: String {
        switch self {
        case .lan: "1.1"
        case .tailscale: "xxx.xxx.xxx"
        case .public: "my-server.com"
        }
    }
}

private let portSuffix = ":8000"

struct LoginView: View {
    @Bindable var store: InterlaceStore
    @Binding var savedBaseURL: String
    @FocusState private var isFieldFocused: Bool
    @State private var iconPhase = false
    @State private var mode: ConnectionMode = .lan
    @State private var useHTTPS = false
    @State private var hostText = ""

    private var schemePrefix: String { useHTTPS ? "https://" : "http://" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { isFieldFocused = false }

            VStack(spacing: 0) {
                Spacer().frame(height: 80)

                // Hero icon
                ZStack {
                    Circle()
                        .fill(Color.interlaceAccent.opacity(0.08))
                        .frame(width: 180, height: 180)

                    // Outer rotating arc
                    Circle()
                        .trim(from: 0.05, to: 0.9)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color.interlaceAccent.opacity(0.0),
                                    Color.interlaceAccent.opacity(0.5),
                                    Color.interlaceAccent.opacity(0.0)
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 180, height: 180)
                        .rotationEffect(.degrees(iconPhase ? 360 : 0))

                    // Inner counter-rotating arc
                    Circle()
                        .trim(from: 0.1, to: 0.85)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color.interlaceAccent.opacity(0.0),
                                    Color.interlaceAccent.opacity(0.35),
                                    Color.interlaceAccent.opacity(0.0)
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .frame(width: 160, height: 160)
                        .rotationEffect(.degrees(iconPhase ? -300 : 60))

                    Image("Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .background(Color(white: 0.06))
                        .clipShape(.rect(cornerRadius: 22))
                }
                .accessibilityHidden(true)

                Spacer().frame(height: 20)

                Text("Interlace")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Connect to your server")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(white: 0.45))
                    .padding(.top, 4)

                Spacer().frame(height: 36)

                // Connection card
                VStack(spacing: 14) {
                    // Mode selector
                    HStack(spacing: 8) {
                        ForEach(ConnectionMode.allCases, id: \.self) { option in
                            Button {
                                mode = option
                                hostText = option.autoPrefix
                            } label: {
                                Text(option.label)
                                    .font(.system(size: 11, weight: .bold))
                                    .tracking(0.5)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(mode == option ? .black : Color(white: 0.5))
                                    .background(mode == option ? Color.interlaceAccent : Color(white: 0.08))
                                    .clipShape(.capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // URL input row
                    HStack(spacing: 0) {
                        Button {
                            useHTTPS.toggle()
                        } label: {
                            Text(schemePrefix)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(Color.interlaceAccent.opacity(0.7))
                                .padding(.trailing, 2)
                        }
                        .buttonStyle(.plain)

                        TextField(mode.placeholder, text: $hostText)
                            .interlaceURLTextInput()
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.white)

                        Text(portSuffix)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Color(white: 0.35))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.06))
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isFieldFocused
                                    ? Color.interlaceAccent.opacity(0.6)
                                    : Color(white: 0.14),
                                lineWidth: 1
                            )
                    )
                    .focused($isFieldFocused)
                    .onSubmit { connect() }
                    .accessibilityLabel("Server address")

                    Button {
                        connect()
                    } label: {
                        HStack(spacing: 8) {
                            if store.isConnecting {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Image(systemName: "arrow.forward")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            Text(store.isConnecting ? "Connecting..." : "Connect")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.interlaceAccent)
                        .foregroundStyle(.black)
                        .clipShape(.rect(cornerRadius: 12))
                    }
                    .disabled(store.isConnecting)
                    .buttonStyle(.plain)
                }
                .padding(24)
                .glossyGlassCard(cornerRadius: 20)
                .padding(.horizontal, 24)

                Spacer()

                Button {
                    store.enterDemoMode()
                } label: {
                    Text("Try Demo")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.interlaceAccent)
                }
                .buttonStyle(.plain)

                Text("No server? Explore the app first.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.3))
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            hostText = mode.autoPrefix
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                iconPhase = true
            }
            if let normalized = try? InterlaceAPI.normalizedBaseURL(from: savedBaseURL) {
                let full = InterlaceAPI.displayString(for: normalized)
                if full.hasPrefix("https://") {
                    useHTTPS = true
                    hostText = String(full.dropFirst(8))
                } else if full.hasPrefix("http://") {
                    useHTTPS = false
                    hostText = String(full.dropFirst(7))
                }
            }
        }
    }

    private func connect() {
        let raw = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        store.baseURLText = schemePrefix + raw + portSuffix
        Task {
            let connected = await store.connect()
            if connected {
                savedBaseURL = store.baseURLText
            }
        }
    }
}
