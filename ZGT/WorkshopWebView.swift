import SwiftUI
import WebKit
import UIKit

struct WorkshopWebView: UIViewRepresentable {
    let siteURL: URL
    let onAppearanceChange: (String, UIStatusBarStyle) -> Void
    let onInitialContentReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            siteURL: siteURL,
            onAppearanceChange: onAppearanceChange,
            onInitialContentReady: onInitialContentReady
        )
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
        config.userContentController.add(
            WeakScriptMessageHandler(delegate: context.coordinator),
            name: "zgtNative"
        )
        config.userContentController.add(
            WeakScriptMessageHandler(delegate: context.coordinator),
            name: "zgtAppearance"
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        context.coordinator.observeForeground()

        let navigationOverlay = UIView()
        navigationOverlay.backgroundColor = context.coordinator.navigationOverlayColor
        navigationOverlay.isOpaque = true
        navigationOverlay.isHidden = true
        navigationOverlay.isUserInteractionEnabled = true
        navigationOverlay.translatesAutoresizingMaskIntoConstraints = false

        let loadingRing = NativeLoadingRingView()
        loadingRing.translatesAutoresizingMaskIntoConstraints = false
        loadingRing.startAnimating(repeats: true)

        navigationOverlay.addSubview(loadingRing)
        webView.addSubview(navigationOverlay)
        NSLayoutConstraint.activate([
            navigationOverlay.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            navigationOverlay.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            navigationOverlay.topAnchor.constraint(equalTo: webView.topAnchor),
            navigationOverlay.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            loadingRing.widthAnchor.constraint(equalToConstant: 22),
            loadingRing.heightAnchor.constraint(equalToConstant: 22),
            loadingRing.centerXAnchor.constraint(equalTo: navigationOverlay.centerXAnchor),
            loadingRing.centerYAnchor.constraint(equalTo: navigationOverlay.centerYAnchor)
        ])
        context.coordinator.navigationOverlay = navigationOverlay

        var request = URLRequest(url: siteURL.appendingPathComponent("wp-admin/"))
        request.cachePolicy = .useProtocolCachePolicy
        webView.load(request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Actualizar callbacks SwiftUI no modifica, recarga ni reconstruye el WKWebView.
        context.coordinator.onAppearanceChange = onAppearanceChange
        context.coordinator.onInitialContentReady = onInitialContentReady
    }

    static let bridgeJavaScript = #"""
    (function () {
        if (window.ZGTNative && window.ZGTNative.__iosBridge) return;
        window.__ZGTNativeNiimbotConnected = false;
        window.ZGTNative = {
            __iosBridge: true,
            appVersion: function () { return '0.1.18'; },
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let siteURL: URL
        weak var webView: WKWebView?
        var onAppearanceChange: (String, UIStatusBarStyle) -> Void
        var onInitialContentReady: () -> Void
        var navigationOverlayColor: UIColor = .black
        weak var navigationOverlay: UIView?

        private lazy var printer = NiimbotB1ProPrinter { [weak self] event in
            self?.sendNativeEvent(event)
        }
        private let contactImporter = ContactImporter()
        private var foregroundObserver: NSObjectProtocol?
        private var didRevealInitialContent = false

        init(
            siteURL: URL,
            onAppearanceChange: @escaping (String, UIStatusBarStyle) -> Void,
            onInitialContentReady: @escaping () -> Void
        ) {
            self.siteURL = siteURL
            self.onAppearanceChange = onAppearanceChange
            self.onInitialContentReady = onInitialContentReady
        }

        deinit {
            if let foregroundObserver {
                NotificationCenter.default.removeObserver(foregroundObserver)
            }
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zgtNative")
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zgtAppearance")
        }

        func observeForeground() {
            guard foregroundObserver == nil else { return }
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.requestAppearance()
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "zgtAppearance" {
                guard let body = message.body as? [String: Any],
                      let backgroundHex = body["backgroundColor"] as? String,
                      let color = UIColor(zgtHex: backgroundHex) else { return }
                let statusBarStyle: UIStatusBarStyle =
                    color.zgtRelativeLuminance > 0.179 ? .darkContent : .lightContent
                navigationOverlayColor = color
                navigationOverlay?.backgroundColor = color
                onAppearanceChange(backgroundHex, statusBarStyle)
                return
            }

            guard message.name == "zgtNative",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "navigationContentReady":
                hideNavigationOverlay()
                revealInitialContentIfNeeded()

            case "initialContentReady":
                hideNavigationOverlay()
                revealInitialContentIfNeeded()

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

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            navigationOverlay?.backgroundColor = navigationOverlayColor
            navigationOverlay?.isHidden = false
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // didCommit only means a response arrived. Keep the opaque cover until a new frame paints.
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if webView.url?.path.contains("wp-login.php") == true {
                webView.evaluateJavaScript(
                    "(function(){var r=document.getElementById('rememberme');if(r){r.checked=true;r.setAttribute('checked','checked');}})();"
                )
            }
            requestAppearance()
            signalNavigationContentReadyAfterPaint(webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            hideNavigationOverlay()
            revealInitialContentIfNeeded()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            hideNavigationOverlay()
            revealInitialContentIfNeeded()
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

        private func requestAppearance() {
            webView?.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('zgtAppearanceRequest'));"
            )
        }

        private func signalNavigationContentReadyAfterPaint(_ webView: WKWebView) {
            webView.evaluateJavaScript("""
            requestAnimationFrame(function () {
                requestAnimationFrame(function () {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.zgtNative) {
                        window.webkit.messageHandlers.zgtNative.postMessage({ action: "navigationContentReady" });
                    }
                });
            });
            """)
        }

        private func hideNavigationOverlay() {
            navigationOverlay?.isHidden = true
        }

        private func revealInitialContentIfNeeded() {
            guard !didRevealInitialContent else { return }
            didRevealInitialContent = true
            onInitialContentReady()
        }

        private func isTrusted(url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https",
                  let allowedHost = siteURL.host?.lowercased(),
                  let host = url.host?.lowercased() else { return false }
            return host == allowedHost || host.hasSuffix(".\(allowedHost)")
        }

        private func isContactExportURL(_ url: URL) -> Bool {
            guard url.path.hasSuffix("/wp-admin/admin-post.php"),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let action = components.queryItems?
                    .first(where: { $0.name == "action" })?
                    .value?
                    .lowercased() else { return false }
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

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

struct ZGTLoadingRing: UIViewRepresentable {
    let repeats: Bool

    func makeUIView(context: Context) -> NativeLoadingRingView {
        let view = NativeLoadingRingView()
        view.startAnimating(repeats: repeats)
        return view
    }

    func updateUIView(_ view: NativeLoadingRingView, context: Context) {
        if view.repeats != repeats {
            view.startAnimating(repeats: repeats)
        }
    }
}

final class NativeLoadingRingView: UIView {
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private(set) var repeats = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        layer.addSublayer(trackLayer)
        layer.addSublayer(progressLayer)

        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor.white.withAlphaComponent(0.10).cgColor
        trackLayer.lineWidth = 1.4

        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.strokeColor = UIColor(red: 234.0 / 255.0, green: 1, blue: 0, alpha: 1).cgColor
        progressLayer.lineWidth = 1.4
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = max(0, min(bounds.width, bounds.height) / 2 - 0.7)
        let circle = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: 3 * .pi / 2,
            clockwise: true
        ).cgPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.path = circle
        progressLayer.frame = bounds
        progressLayer.path = circle
        CATransaction.commit()
    }

    func startAnimating(repeats: Bool) {
        self.repeats = repeats
        progressLayer.removeAnimation(forKey: "zgtRingProgress")
        progressLayer.strokeEnd = 1

        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.42
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        if repeats {
            animation.repeatCount = .infinity
        }
        progressLayer.add(animation, forKey: "zgtRingProgress")
    }
}
