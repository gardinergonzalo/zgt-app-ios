import SwiftUI
import WebKit
import UIKit

struct WorkshopWebView: UIViewRepresentable {
    let siteURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(siteURL: siteURL)
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

        let webView = WKWebView(frame: .zero, configuration: config)
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

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static let bridgeJavaScript = #"""
    (function () {
        if (window.ZGTNative && window.ZGTNative.__iosBridge) return;
        window.__ZGTNativeNiimbotConnected = false;
        window.ZGTNative = {
            __iosBridge: true,
            appVersion: function () { return '0.1.5'; },
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
        weak var webView: WKWebView?
        private lazy var printer = NiimbotB1ProPrinter { [weak self] event in
            self?.sendNativeEvent(event)
        }

        init(siteURL: URL) {
            self.siteURL = siteURL
        }

        deinit {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zgtNative")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
                DispatchQueue.main.async { [weak self] in
                    self?.printer.print(dataURL: dataURL)
                }

            case "disconnectNiimbotB1Pro":
                DispatchQueue.main.async { [weak self] in
                    self?.printer.disconnect()
                }

            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if isTrusted(url: url) {
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
