import SwiftUI
import SharedSoundCore

#if os(macOS)
import AppKit
#endif

@main
struct SharedSoundApp: App {
    @StateObject private var session = SessionViewModel()

    init() {
        #if os(macOS)
        // `swift run` launches us as a plain CLI process, so the Dock and
        // windows are hidden by default. Force a real GUI activation policy
        // so the window actually appears.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup("SharedSound") {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 520, minHeight: 680)
                .preferredColorScheme(.dark)
                .task { session.start() }
        }
    }
}
