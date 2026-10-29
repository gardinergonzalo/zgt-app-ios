import Contacts
import ContactsUI
import UIKit
import WebKit

@MainActor
final class ContactImporter: NSObject, CNContactViewControllerDelegate {
    private var isLoading = false

    func importContact(from url: URL, webView: WKWebView) {
        guard !isLoading else { return }
        isLoading = true

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
            guard let self, let webView else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(
                "text/vcard, text/x-vcard, text/directory, */*;q=0.8",
                forHTTPHeaderField: "Accept"
            )

            if let referer = webView.url?.absoluteString {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }

            let matchingCookies = cookies.filter { cookie in
                Self.cookie(cookie, matches: url)
            }

            if let cookieHeader = HTTPCookie.requestHeaderFields(
                with: matchingCookies
            )["Cookie"], !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isLoading = false

                    if let error {
                        self.showError(
                            "No se pudo obtener el contacto. Revisá tu conexión e intentá nuevamente.",
                            webView: webView,
                            detail: error.localizedDescription
                        )
                        return
                    }

                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode),
                          let data,
                          !data.isEmpty,
                          data.count <= 1_000_000 else {
                        self.showError(
                            "No se pudo obtener el contacto desde ZGT.",
                            webView: webView
                        )
                        return
                    }

                    guard Self.looksLikeVCard(data) else {
                        self.showError(
                            "ZGT no recibió una ficha de contacto válida. Verificá que la sesión siga iniciada.",
                            webView: webView
                        )
                        return
                    }

                    do {
                        guard let contact = try CNContactVCardSerialization
                            .contacts(with: data)
                            .first,
                              let mutable = contact.mutableCopy() as? CNMutableContact else {
                            throw ContactImportError.invalidVCard
                        }

                        self.presentContactEditor(
                            contact: mutable,
                            webView: webView
                        )
                    } catch {
                        self.showError(
                            "No se pudo leer el contacto generado por ZGT.",
                            webView: webView,
                            detail: error.localizedDescription
                        )
                    }
                }
            }.resume()
        }
    }

    func contactViewController(
        _ viewController: CNContactViewController,
        didCompleteWith contact: CNContact?
    ) {
        viewController.navigationController?.dismiss(animated: true)
    }

    private func presentContactEditor(
        contact: CNMutableContact,
        webView: WKWebView
    ) {
        guard let presenter = Self.topViewController(from: webView) else {
            showError(
                "No se pudo abrir el editor de contactos.",
                webView: webView
            )
            return
        }

        let editor = CNContactViewController(forNewContact: contact)
        editor.delegate = self

        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .formSheet
        presenter.present(navigation, animated: true)
    }

    private func showError(
        _ message: String,
        webView: WKWebView,
        detail: String? = nil
    ) {
        guard let presenter = Self.topViewController(from: webView) else {
            return
        }

        let fullMessage: String
        if let detail, !detail.isEmpty {
            fullMessage = "\(message)\n\n\(detail)"
        } else {
            fullMessage = message
        }

        let alert = UIAlertController(
            title: "Agregar a contactos",
            message: fullMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default))
        presenter.present(alert, animated: true)
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        guard host == domain || host.hasSuffix(".\(domain)") else {
            return false
        }

        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }

    private static func looksLikeVCard(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }

        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .hasPrefix("BEGIN:VCARD")
    }

    private static func topViewController(from webView: WKWebView) -> UIViewController? {
        var controller = webView.window?.rootViewController

        while let presented = controller?.presentedViewController {
            controller = presented
        }

        if let navigation = controller as? UINavigationController {
            return navigation.visibleViewController ?? navigation
        }

        if let tab = controller as? UITabBarController {
            return tab.selectedViewController ?? tab
        }

        return controller
    }

    private enum ContactImportError: LocalizedError {
        case invalidVCard

        var errorDescription: String? {
            "La vCard está vacía o no tiene un formato compatible."
        }
    }
}
