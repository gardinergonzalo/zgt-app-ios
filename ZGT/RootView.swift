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

            VStack(spacing: 26) {
                Image("ZeozLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 154, height: 100)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color(red: 234 / 255, green: 1, blue: 0))
                    .scaleEffect(1.15)
            }
        }
    }
}
