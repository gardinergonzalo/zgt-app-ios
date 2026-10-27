import SwiftUI

@main
struct ZGTApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var appearance = AppearanceState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appearance)
        }
    }
}
