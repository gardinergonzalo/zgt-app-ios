import SwiftUI
import WebKit

struct WorkshopScreen: View {
    @StateObject private var session: WorkshopSession

    init(siteURL: URL, appearance: AppearanceState) {
        _session = StateObject(
            wrappedValue: WorkshopSession(
                siteURL: siteURL,
                appearance: appearance
            )
        )
    }

    var body: some View {
        ZStack {
            PersistentWebView(webView: session.webView)
                .ignoresSafeArea(.container, edges: .bottom)

            if !session.isInitialLoadComplete {
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(
            .easeOut(duration: 0.12),
            value: session.isInitialLoadComplete
        )
    }
}

private struct PersistentWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(
        _ webView: WKWebView,
        context: Context
    ) {
        // Intencionalmente vacío:
        // SwiftUI nunca modifica ni recrea la sesión web por un cambio de tema.
    }
}
