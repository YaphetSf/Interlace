import SwiftUI

struct LoginView: View {
    let store: WatchLibraryStore
    @State private var iconPhase = false
    @State private var showingLANEntry = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                hero

                Text("Interlace")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await store.connect() }
                } label: {
                    connectionButtonLabel(
                        title: store.isConnecting ? "Connecting…" : "Connect via iPhone",
                        systemImage: "iphone",
                        progressTint: .white
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(store.canRelayThroughPhone ? .green : .gray)
                .disabled(store.isConnecting || !store.canRelayThroughPhone)

                Button {
                    showingLANEntry = true
                } label: {
                    connectionButtonLabel(
                        title: store.isConnecting ? "Connecting…" : "Connect via LAN",
                        systemImage: "network"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(store.isConnecting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingLANEntry) {
            LANEntryView(store: store)
        }
    }

    private var hero: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 100, height: 100)

            ring(lineWidth: 2, opacity: 0.5, frame: 100, trim: 0.05...0.9, rotation: iconPhase ? 360 : 0)
            ring(lineWidth: 1.5, opacity: 0.35, frame: 88, trim: 0.1...0.85, rotation: iconPhase ? -300 : 60)

            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 12))
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                iconPhase = true
            }
        }
    }

    private func ring(
        lineWidth: CGFloat,
        opacity: Double,
        frame: CGFloat,
        trim: ClosedRange<CGFloat>,
        rotation: Double
    ) -> some View {
        Circle()
            .trim(from: trim.lowerBound, to: trim.upperBound)
            .stroke(
                AngularGradient(
                    colors: [.blue.opacity(0), .blue.opacity(opacity), .blue.opacity(0)],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: frame, height: frame)
            .rotationEffect(.degrees(rotation))
    }

    private func connectionButtonLabel(title: String, systemImage: String, progressTint: Color? = nil) -> some View {
        HStack(spacing: 6) {
            ZStack {
                if store.isConnecting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(progressTint)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .frame(width: 16, height: 16)

            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity)
    }
}

/// IP entry presented from "Connect via LAN". The `192.168.` prefix and the
/// default `:8000` port are fixed, so the user just fills the last two octets
/// in numeric fields (watchOS shows its number pad for `Int`-bound fields).
private struct LANEntryView: View {
    let store: WatchLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var octet3: Int?
    @State private var octet4: Int?
    @FocusState private var focusedOctet: Int?

    private var isValid: Bool {
        [octet3, octet4].allSatisfy { value in
            guard let value else { return false }
            return (0...255).contains(value)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack(spacing: 2) {
                        Text(verbatim: "192.168.")
                            .foregroundStyle(.secondary)
                        octetField($octet3, placeholder: "1", focus: 3)
                        Text(verbatim: ".")
                        octetField($octet4, placeholder: "1", focus: 4)
                        Text(verbatim: ":8000")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 15, design: .monospaced))

                    Button(action: connect) {
                        HStack(spacing: 6) {
                            if store.isConnecting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .tint(.white)
                            } else {
                                Image(systemName: "network")
                            }
                            Text(store.isConnecting ? "Connecting…" : "Connect")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(store.isConnecting || !isValid)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
            .navigationTitle("Server IP")
        }
        .onAppear {
            seedFromSavedURL()
            if octet3 == nil { focusedOctet = 3 }
        }
    }

    private func octetField(_ value: Binding<Int?>, placeholder: String, focus: Int) -> some View {
        TextField(placeholder, value: value, format: .number.grouping(.never))
            .multilineTextAlignment(.center)
            .frame(width: 40)
            .focused($focusedOctet, equals: focus)
    }

    private func seedFromSavedURL() {
        let host = store.baseURLText
            .components(separatedBy: "://").last?
            .components(separatedBy: "/").first?
            .components(separatedBy: ":").first ?? ""
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "192", parts[1] == "168" {
            octet3 = Int(parts[2])
            octet4 = Int(parts[3])
        }
    }

    private func connect() {
        guard let octet3, let octet4 else { return }
        store.baseURLText = "192.168.\(octet3).\(octet4):8000"
        Task {
            if await store.connect() {
                dismiss()
            }
        }
    }
}
