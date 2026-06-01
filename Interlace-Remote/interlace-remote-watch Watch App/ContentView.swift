import SwiftUI

struct ContentView: View {
    @AppStorage("interlace.watch.baseURL") private var savedBaseURL = ""
    // Remembers that the last successful connection was an iPhone relay, so we
    // can auto-reconnect through the phone even when no LAN URL was ever saved.
    @AppStorage("interlace.watch.usePhoneRelay") private var usePhoneRelay = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WatchLibraryStore()

    var body: some View {
        Group {
            if store.isConnected {
                LibraryView(store: store, savedBaseURL: $savedBaseURL, usePhoneRelay: $usePhoneRelay)
            } else {
                LoginView(store: store)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.configureSavedBaseURL(savedBaseURL)
        }
        .task(id: savedBaseURL) {
            await connectToSavedServerIfNeeded()
        }
        // Single place that persists the connection once it succeeds, regardless
        // of which path won (auto-reconnect, iPhone button, or LAN sheet).
        .onChange(of: store.isConnected) { _, connected in
            guard connected else { return }
            if store.usingPhoneRelay {
                usePhoneRelay = true
            } else {
                savedBaseURL = store.baseURLText
                usePhoneRelay = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard store.isConnected else {
                store.stopPlayerPolling()
                return
            }
            if phase == .active {
                store.startPlayerPolling()
                Task {
                    await store.refreshLibrary(silent: true)
                    await store.refreshPlayer(silent: true)
                }
            } else {
                store.stopPlayerPolling()
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

    private func connectToSavedServerIfNeeded() async {
        guard !store.isConnected, !store.isConnecting else { return }
        let trimmedBaseURL = savedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Auto-reconnect only if there's something to reconnect to: a saved LAN
        // URL (tried first by `connect()`) or a remembered iPhone-relay session.
        guard !trimmedBaseURL.isEmpty || usePhoneRelay else { return }
        if !trimmedBaseURL.isEmpty {
            store.configureSavedBaseURL(trimmedBaseURL)
        }
        _ = await store.connect()
    }
}

#Preview {
    ContentView()
}
