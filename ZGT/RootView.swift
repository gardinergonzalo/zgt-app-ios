import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.isBooting {
                SplashView()
            } else if let siteURL = appState.siteURL {
                WorkshopWebView(siteURL: siteURL)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                LinkView()
            }
        }
        .background(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255))
    }
}

private struct SplashView: View {
    var body: some View {
        ZStack {
            Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
                .ignoresSafeArea()
            Text("Z")
                .font(.system(size: 74, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 234 / 255, green: 1, blue: 0))
        }
    }
}
