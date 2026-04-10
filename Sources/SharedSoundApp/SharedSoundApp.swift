import SwiftUI
import SharedSoundCore

@main
struct SharedSoundApp: App {
    @StateObject private var session = SessionViewModel()

    var body: some Scene {
        WindowGroup("SharedSound") {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 420, minHeight: 480)
                .task { session.start() }
        }
    }
}
