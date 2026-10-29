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
        // Intencionalmente vacío.
        // El WKWebView y la navegación pertenecen al controlador UIKit.
    }
}

final class WorkshopViewController: UIViewController,
    WKNavigationDelegate,
    WKUIDelegate,
    WKScriptMessageHandler {

    private let siteURL: URL
    private var webView: WKWebView!
    private let statusBarBackgroundView = UIView()
    private let loadingOverlay = UIView()
    private var didRevealInitialContent = false

    private var nativeHandlerProxy: WeakScriptMessageHandler?
    private var appearanceHandlerProxy: WeakScriptMessageHandler?

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

        let startupColor = UIColor(
            red: 20 / 255,
            green: 20 / 255,
            blue: 20 / 255,
            alpha: 1
        )

        view.backgroundColor = startupColor

        statusBarBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        statusBarBackgroundView.backgroundColor = startupColor
        view.addSubview(statusBarBackgroundView)

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

        let nativeProxy = WeakScriptMessageHandler(delegate: self)
        let appearanceProxy = WeakScriptMessageHandler(delegate: self)
        nativeHandlerProxy = nativeProxy
        appearanceHandlerProxy = appearanceProxy
        config.userContentController.add(nativeProxy, name: "zgtNative")
        config.userContentController.add(appearanceProxy, name: "zgtAppearance")

        let webView = WKWebView(frame: .zero, configuration: config)
        self.webView = webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)

        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.backgroundColor = startupColor
        view.addSubview(loadingOverlay)

        NSLayoutConstraint.activate([
            statusBarBackgroundView.topAnchor.constraint(
                equalTo: view.topAnchor
            ),
            statusBarBackgroundView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            statusBarBackgroundView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            statusBarBackgroundView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor
            ),

            webView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor
            ),
            webView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            webView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            webView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            ),

            loadingOverlay.topAnchor.constraint(
                equalTo: view.topAnchor
            ),
            loadingOverlay.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            loadingOverlay.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            loadingOverlay.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            )
        ])

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

            applyNativeAppearance(color: color)
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
                    .error(
                        "La etiqueta enviada por ZGT no tiene un formato válido."
                    )
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
        revealInitialContentIfNeeded()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        revealInitialContentIfNeeded()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        revealInitialContentIfNeeded()
    }

    @objc private func appWillEnterForeground() {
        requestAppearance()
    }

    private func requestAppearance() {
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('zgtAppearanceRequest'));"
        )
    }

    private func revealInitialContentIfNeeded() {
        guard !didRevealInitialContent else { return }
        didRevealInitialContent = true

        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [
                .beginFromCurrentState,
                .allowUserInteraction
            ]
        ) {
            self.loadingOverlay.alpha = 0
        } completion: { _ in
            self.loadingOverlay.removeFromSuperview()
        }
    }

    private func applyNativeAppearance(color: UIColor) {
        statusBarBackgroundView.backgroundColor = color

        let luminance = color.zgtLuminance
        UIApplication.shared.statusBarStyle =
            luminance > 0.56 ? .darkContent : .lightContent
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

private final class WeakScriptMessageHandler: NSObject,
    WKScriptMessageHandler {

    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(
            userContentController,
            didReceive: message
        )
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
