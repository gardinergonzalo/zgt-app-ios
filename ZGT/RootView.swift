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
    @State private var progress: CGFloat = 0

    private let lime = Color(red: 234 / 255, green: 1, blue: 0)

    var body: some View {
        ZStack {
            Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
                .ignoresSafeArea()

            VStack(spacing: 40) {
                Image("ZeozLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 154, height: 100)

                ZStack {
                    Circle()
                        .stroke(lime.opacity(0.18), lineWidth: 2)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            lime,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 32, height: 32)
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
