import SwiftUI
import WebKit
import UIKit

@MainActor
final class WorkshopSession: NSObject, ObservableObject,
    WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    @Published private(set) var isInitialLoadComplete = false

    let siteURL: URL
    let appearance: AppearanceState
    let webView: WKWebView

    private lazy var printer = NiimbotB1ProPrinter { [weak self] event in
        self?.sendNativeEvent(event)
    }
    private let contactImporter = ContactImporter()

    init(siteURL: URL, appearance: AppearanceState) {
        self.siteURL = siteURL
        self.appearance = appearance

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

        self.webView = WKWebView(
            frame: .zero,
            configuration: config
        )

        super.init()

        config.userContentController.add(self, name: "zgtNative")
        config.userContentController.add(self, name: "zgtAppearance")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        var request = URLRequest(
            url: siteURL.appendingPathComponent("wp-admin/")
        )
        request.cachePolicy = .useProtocolCachePolicy
        webView.load(request)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "zgtNative")
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "zgtAppearance")
    }

    static let bridgeJavaScript = #"""
    (function () {
        if (window.ZGTNative && window.ZGTNative.__iosBridge) return;
        window.__ZGTNativeNiimbotConnected = false;
        window.ZGTNative = {
            __iosBridge: true,
            appVersion: function () { return '0.1.15'; },
            printNiimbotB1Pro: function (dataUrl) {
                window.webkit.messageHandlers.zgtNative.postMessage({
                    action: 'printNiimbotB1Pro',
                    dataUrl: String(dataUrl || '')
                });
            },
            disconnectNiimbotB1Pro: function () {
                window.webkit.messageHandlers.zgtNative.postMessage({
                    action: 'disconnectNiimbotB1Pro'
                });
            },
            isNiimbotB1ProConnected: function () {
                return window.__ZGTNativeNiimbotConnected === true;
            }
        };
    })();
    """#

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "zgtAppearance" {
            guard let body = message.body as? [String: Any],
                  let backgroundColor = body["backgroundColor"] as? String else {
                return
            }

            appearance.apply(
                theme: body["theme"] as? String,
                backgroundHex: backgroundColor
            )
            return
        }

        guard message.name == "zgtNative",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            return
        }

        switch action {
        case "printNiimbotB1Pro":
            guard let dataURL = body["dataUrl"] as? String,
                  dataURL.hasPrefix("data:image/png;base64,"),
                  dataURL.count <= 3_000_000 else {
                sendNativeEvent(
                    .error("La etiqueta enviada por ZGT no tiene un formato válido.")
                )
                return
            }
            printer.print(dataURL: dataURL)

        case "disconnectNiimbotB1Pro":
            printer.disconnect()

        default:
            break
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if isTrusted(url: url), isContactExportURL(url) {
            decisionHandler(.cancel)
            contactImporter.importContact(
                from: url,
                webView: webView
            )
        } else if isTrusted(url: url) {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        if webView.url?.path.contains("wp-login.php") == true {
            webView.evaluateJavaScript(
                "(function(){var r=document.getElementById('rememberme');if(r){r.checked=true;r.setAttribute('checked','checked');}})();"
            )
        }

        requestAppearance()
        if !isInitialLoadComplete {
            isInitialLoadComplete = true
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        if !isInitialLoadComplete {
            isInitialLoadComplete = true
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if !isInitialLoadComplete {
            isInitialLoadComplete = true
        }
    }

    @objc private func appWillEnterForeground() {
        appearance.reapply()
        requestAppearance()
    }

    private func requestAppearance() {
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
              let host = origin.host
                .addingPercentEncoding(
                    withAllowedCharacters: .urlHostAllowed
                ),
              let url = URL(string: "https://\(host)") else {
            decisionHandler(.deny)
            return
        }

        decisionHandler(
            isTrusted(url: url) ? .grant : .deny
        )
    }

    private func isTrusted(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let allowedHost = siteURL.host?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }

        return host == allowedHost ||
            host.hasSuffix(".\(allowedHost)")
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

        return action.hasPrefix("gtm_contacto_")
    }

    private func sendNativeEvent(_ event: NiimbotNativeEvent) {
        let connected = printer.isConnected
        let payload: [String: String] = [
            "type": event.type,
            "message": event.message
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload
        ),
        let json = String(
            data: data,
            encoding: .utf8
        ) else {
            return
        }

        let script = """
        window.__ZGTNativeNiimbotConnected = \(connected ? "true" : "false");
        if (window.ZEOZZGTPrintNativeCallback) {
            window.ZEOZZGTPrintNativeCallback(\(json));
        }
        """
        webView.evaluateJavaScript(script)
    }
}
