import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appearance: AppearanceState

    private let defaultBackground = Color(
        red: 20 / 255,
        green: 20 / 255,
        blue: 20 / 255
    )

    var body: some View {
        Group {
            if appState.isBooting {
                SplashView(background: defaultBackground)
                    .preferredColorScheme(.dark)
            } else if let siteURL = appState.siteURL {
                WorkshopWebView(siteURL: siteURL)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .background(appearance.backgroundColor.ignoresSafeArea())
            } else {
                LinkView()
                    .preferredColorScheme(.dark)
            }
        }
        .background(
            (appState.siteURL == nil
                ? defaultBackground
                : appearance.backgroundColor
            )
            .ignoresSafeArea()
        )
        .onAppear {
            appearance.reapply()
        }
    }
}

private struct SplashView: View {
    @State private var progress: CGFloat = 0

    let background: Color
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
