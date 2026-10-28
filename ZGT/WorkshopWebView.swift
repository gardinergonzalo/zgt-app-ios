import SwiftUI
import WebKit
import UIKit

struct WorkshopWebView: UIViewRepresentable {
    @EnvironmentObject private var appearance: AppearanceState
    let siteURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(siteURL: siteURL, appearance: appearance)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true

        let bridgeScript = WKUserScript(
            source: Self.bridgeJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(bridgeScript)
        config.userContentController.add(context.coordinator, name: "zgtNative")
        config.userContentController.add(context.coordinator, name: "zgtAppearance")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = appearance.uiColor
        webView.scrollView.backgroundColor = appearance.uiColor
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = appearance.uiColor
        }
        // Evita mostrar el fondo blanco por defecto de WebKit mientras
        // WordPress todavía está cargando su CSS.
        webView.alpha = 0
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView

        var request = URLRequest(url: siteURL.appendingPathComponent("wp-admin/"))
        request.cachePolicy = .useProtocolCachePolicy
        webView.load(request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Cambiar el tema no recrea ni recarga el WKWebView. Sólo actualizamos
        // el color que queda detrás del documento y de la safe-area.
        webView.backgroundColor = appearance.uiColor
        webView.scrollView.backgroundColor = appearance.uiColor
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = appearance.uiColor
        }
    }

    static let bridgeJavaScript = #"""
    (function () {
        if (window.ZGTNative && window.ZGTNative.__iosBridge) return;
        window.__ZGTNativeNiimbotConnected = false;
        window.ZGTNative = {
            __iosBridge: true,
            appVersion: function () { return '0.1.12'; },
            printNiimbotB1Pro: function (dataUrl) {
                window.webkit.messageHandlers.zgtNative.postMessage({ action: 'printNiimbotB1Pro', dataUrl: String(dataUrl || '') });
            },
            disconnectNiimbotB1Pro: function () {
                window.webkit.messageHandlers.zgtNative.postMessage({ action: 'disconnectNiimbotB1Pro' });
            },
            isNiimbotB1ProConnected: function () {
                return window.__ZGTNativeNiimbotConnected === true;
            }
        };
    })();
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let siteURL: URL
        let appearance: AppearanceState
        weak var webView: WKWebView?
        private lazy var printer = NiimbotB1ProPrinter { [weak self] event in
            self?.sendNativeEvent(event)
        }
        private let contactImporter = ContactImporter()
        private var hasShownInitialContent = false

        init(siteURL: URL, appearance: AppearanceState) {
            self.siteURL = siteURL
            self.appearance = appearance
            super.init()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appWillEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zgtNative")
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zgtAppearance")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "zgtAppearance" {
                guard let body = message.body as? [String: Any],
                      let backgroundColor = body["backgroundColor"] as? String else {
                    return
                }

                let theme = body["theme"] as? String
                Task { @MainActor [weak self] in
                    self?.appearance.apply(
                        theme: theme,
                        backgroundHex: backgroundColor
                    )
                }
                return
            }

            guard message.name == "zgtNative",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "printNiimbotB1Pro":
                guard let dataURL = body["dataUrl"] as? String,
                      dataURL.hasPrefix("data:image/png;base64,"),
                      dataURL.count <= 3_000_000 else {
                    sendNativeEvent(.error("La etiqueta enviada por ZGT no tiene un formato válido."))
                    return
                }
                printer.print(dataURL: dataURL)

            case "disconnectNiimbotB1Pro":
                printer.disconnect()

            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if isTrusted(url: url), isContactExportURL(url) {
                decisionHandler(.cancel)
                contactImporter.importContact(from: url, webView: webView)
            } else if isTrusted(url: url) {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if webView.url?.path.contains("wp-login.php") == true {
                webView.evaluateJavaScript(
                    "(function(){var r=document.getElementById('rememberme');if(r){r.checked=true;r.setAttribute('checked','checked');}})();"
                )
            }

            requestAppearance(from: webView)
            revealInitialContentIfNeeded(webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            revealInitialContentIfNeeded(webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            revealInitialContentIfNeeded(webView)
        }

        private func revealInitialContentIfNeeded(_ webView: WKWebView) {
            guard !hasShownInitialContent else { return }
            hasShownInitialContent = true

            UIView.animate(
                withDuration: 0.12,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                webView.alpha = 1
            }
        }

        @objc private func appWillEnterForeground() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appearance.reapply()
                if let webView = self.webView {
                    self.requestAppearance(from: webView)
                }
            }
        }

        private func requestAppearance(from webView: WKWebView) {
            webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('zgtAppearanceRequest'));"
            )
        }

        @available(iOS 15.0, *)
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            guard type == .camera,
                  let host = origin.host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
                  let url = URL(string: "https://\(host)") else {
                decisionHandler(.deny)
                return
            }
            decisionHandler(isTrusted(url: url) ? .grant : .deny)
        }

        private func isTrusted(url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https",
                  let allowedHost = siteURL.host?.lowercased(),
                  let host = url.host?.lowercased() else { return false }
            return host == allowedHost || host.hasSuffix(".\(allowedHost)")
        }

        private func isContactExportURL(_ url: URL) -> Bool {
            guard url.path.hasSuffix("/wp-admin/admin-post.php"),
                  let components = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                  ),
                  let action = components.queryItems?
                    .first(where: { $0.name == "action" })?
                    .value?
                    .lowercased() else {
                return false
            }

            // Cubre Clientes y Proveedores sin acoplar la app a un ID concreto.
            // La WebView sólo deriva al editor nativo las acciones de contacto
            // del Gestor; el resto de admin-post continúa funcionando normal.
            return action.hasPrefix("gtm_contacto_")
        }

        private func sendNativeEvent(_ event: NiimbotNativeEvent) {
            guard let webView else { return }
            let connected = printer.isConnected
            let payload: [String: String] = [
                "type": event.type,
                "message": event.message
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }

            let script = """
            window.__ZGTNativeNiimbotConnected = \(connected ? "true" : "false");
            if (window.ZEOZZGTPrintNativeCallback) {
                window.ZEOZZGTPrintNativeCallback(\(json));
            }
            """
            webView.evaluateJavaScript(script)
        }
    }
}
