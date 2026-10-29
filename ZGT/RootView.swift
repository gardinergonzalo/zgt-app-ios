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
                    } else {
                        Color.black
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
    @State private var progress: CGFloat = 0

    private let background = Color.black
    private let lime = Color(red: 234 / 255, green: 1, blue: 0)

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                Image("ZeozLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 184, height: 118)

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1.4)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            lime,
                            style: StrokeStyle(
                                lineWidth: 1.4,
                                lineCap: .round
                            )
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
                .padding(.top, 26)
            }
        }
        .onAppear {
            progress = 0
            withAnimation(.linear(duration: 0.42)) {
                progress = 1
            }
        }
    }
}
