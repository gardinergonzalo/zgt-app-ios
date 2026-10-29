import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let siteURL = appState.siteURL {
                ZStack(alignment: .top) {
                    WorkshopWebView(
                        siteURL: siteURL,
                        onAppearanceChange: { backgroundColorHex, statusBarStyle in
                            appState.applyNativeAppearance(
                                backgroundColorHex: backgroundColorHex,
                                statusBarStyle: statusBarStyle
                            )
                        },
                        onInitialContentReady: {
                            appState.revealWebContent()
                        }
                    )
                    .ignoresSafeArea(.container, edges: [.top, .bottom])

                    if appState.isBooting || !appState.isWebContentReady {
                        SplashView()
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                            .zIndex(1)
                    }

                    if !appState.isBooting && appState.isWebContentReady {
                        SafeAreaTopSurface(backgroundColorHex: appState.topSafeAreaColorHex)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                            .zIndex(2)
                    }
                }
            } else if appState.isBooting {
                SplashView()
            } else {
                LinkView()
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct SplashView: View {
    private let background = Color.black

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                Image("ZeozLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 184, height: 118)

                ZGTLoadingRing(repeats: false)
                    .frame(width: 22, height: 22)
                    .padding(.top, 26)
            }
        }
    }
}
