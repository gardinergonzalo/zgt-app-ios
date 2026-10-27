import SwiftUI
import UIKit

@MainActor
final class AppearanceState: ObservableObject {
    @Published private(set) var backgroundColor: Color
    @Published private(set) var colorScheme: ColorScheme

    private let defaults = UserDefaults.standard
    private var nativeBackgroundColor: UIColor
    private var resolvedTheme: String

    private static let defaultBackgroundHex = "#141414"

    init() {
        let savedHex = UserDefaults.standard.string(forKey: "zgt_appearance_background")
            ?? Self.defaultBackgroundHex
        let savedTheme = UserDefaults.standard.string(forKey: "zgt_appearance_theme")
            ?? "dark"
        let color = UIColor(zgtHex: savedHex)
            ?? UIColor(red: 20 / 255, green: 20 / 255, blue: 20 / 255, alpha: 1)

        nativeBackgroundColor = color
        resolvedTheme = savedTheme
        backgroundColor = Color(uiColor: color)
        colorScheme = Self.scheme(for: color)
    }

    func apply(theme: String?, backgroundHex: String) {
        guard let color = UIColor(zgtHex: backgroundHex) else {
            return
        }

        let normalizedTheme = theme?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        nativeBackgroundColor = color
        resolvedTheme = normalizedTheme?.isEmpty == false
            ? normalizedTheme!
            : (Self.scheme(for: color) == .dark ? "dark" : "light")

        backgroundColor = Color(uiColor: color)
        colorScheme = Self.scheme(for: color)

        defaults.set(backgroundHex, forKey: "zgt_appearance_background")
        defaults.set(resolvedTheme, forKey: "zgt_appearance_theme")

        applyToNativeWindows()
    }

    func reapply() {
        applyToNativeWindows()
    }

    private func applyToNativeWindows() {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light

        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { window in
                window.backgroundColor = nativeBackgroundColor
                window.overrideUserInterfaceStyle = style
                window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            }
    }

    private static func scheme(for color: UIColor) -> ColorScheme {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .dark
        }

        // Contraste de la barra de estado: fondos claros usan iconos oscuros
        // y fondos oscuros usan iconos claros.
        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        return luminance > 0.56 ? .light : .dark
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
}
