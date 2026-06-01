//
//  Interlace_RemoteApp.swift
//  Interlace-Remote
//
//  Created by Ding Zhong on 27/05/2026.
//

import SwiftUI

@main
struct Interlace_RemoteApp: App {
    init() {
        // Start listening for relayed requests from the Apple Watch as early as
        // possible, so the watch can reach the server through this phone even
        // when the app was launched into the background by an incoming message.
        WatchRelayServer.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
