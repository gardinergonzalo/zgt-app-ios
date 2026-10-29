import SwiftUI
import WebKit
import UIKit

struct WorkshopWebView: UIViewControllerRepresentable {
    let siteURL: URL

    func makeUIViewController(context: Context) -> WorkshopViewController {
        WorkshopViewController(siteURL: siteURL)
    }

    func updateUIViewController(
        _ uiViewController: WorkshopViewController,
        context: Context
    ) {
        // Intencionalmente vacío. El tema nativo nunca modifica ni reconstruye
        // el WKWebView durante una sesión.
    }
}

final class WorkshopViewController: UIViewController,
    WKNavigationDelegate,
    WKUIDelegate,
    WKScriptMessageHandler {

    private let siteURL: URL
    private var webView: WKWebView!
    private var loadingOverlay: UIView?
    private lazy var printer = NiimbotB1ProPrinter { [weak self] event in
        self?.sendNativeEvent(event)
    }
    private let contactImporter = ContactImporter()

    init(siteURL: URL) {
        self.siteURL = siteURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // El arranque de ZGT es siempre negro. Después de cargar, este fondo
        // queda visible únicamente en la safe-area superior.
        view.backgroundColor = UIColor(
            red: 20 / 255,
            green: 20 / 255,
            blue: 20 / 255,
            alpha: 1
        )

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
        config.userContentController.add(self, name: "zgtNative")
        config.userContentController.add(self, name: "zgtAppearance")

        let webView = WKWebView(frame: .zero, configuration: config)
        self.webView = webView

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        view.addSubview(webView)

        // El WebView comienza debajo de la barra de estado, igual que en la
        // versión estable. La vista del controlador ocupa también la safe-area
        // superior y es la única superficie nativa cuyo color sincronizamos.
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor
            ),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        installInitialBlackOverlay()

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
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "zgtNative")
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "zgtAppearance")
    }

    private func installInitialBlackOverlay() {
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor(
            red: 20 / 255,
            green: 20 / 255,
            blue: 20 / 255,
            alpha: 1
        )

        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        loadingOverlay = overlay
    }

    private func removeInitialBlackOverlay() {
        guard let overlay = loadingOverlay else { return }
        loadingOverlay = nil

        UIView.animate(
            withDuration: 0.12,
            animations: {
                overlay.alpha = 0
            },
            completion: { _ in
                overlay.removeFromSuperview()
            }
        )
    }

    static let bridgeJavaScript = #"""
    (function () {
        if (window.ZGTNative && window.ZGTNative.__iosBridge) return;
        window.__ZGTNativeNiimbotConnected = false;
        window.ZGTNative = {
            __iosBridge: true,
            appVersion: function () { return '0.1.16'; },
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
                  let backgroundHex = body["backgroundColor"] as? String,
                  let color = UIColor(zgtHex: backgroundHex) else {
                return
            }

            applyNativeTopAppearance(color: color)
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

    private func applyNativeTopAppearance(color: UIColor) {
        // Sólo cambia la superficie nativa que está detrás de hora/batería.
        // No se modifica ninguna propiedad del WKWebView.
        view.backgroundColor = color

        let style: UIStatusBarStyle =
            color.zgtLuminance > 0.56
                ? .darkContent
                : .lightContent

        UIApplication.shared.statusBarStyle = style
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
        removeInitialBlackOverlay()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        removeInitialBlackOverlay()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        removeInitialBlackOverlay()
    }

    @objc private func appWillEnterForeground() {
        requestAppearance()
    }

    private func requestAppearance() {
        webView?.evaluateJavaScript(
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
        guard let webView else { return }

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

private extension UIColor {
    convenience init?(zgtHex value: String) {
        var hex = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }

        guard hex.count == 6,
              let number = UInt64(hex, radix: 16) else {
            return nil
        }

        self.init(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }

    var zgtLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        ) else {
            return 0
        }

        return (0.2126 * red) +
            (0.7152 * green) +
            (0.0722 * blue)
    }
}
