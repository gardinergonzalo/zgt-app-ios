import SwiftUI
import UIKit

struct SafeAreaTopSurface: UIViewRepresentable {
    let backgroundColorHex: String

    func makeUIView(context: Context) -> NativeSafeAreaTopSurfaceView {
        let view = NativeSafeAreaTopSurfaceView()
        view.backgroundColorHex = backgroundColorHex
        return view
    }

    func updateUIView(_ view: NativeSafeAreaTopSurfaceView, context: Context) {
        view.backgroundColorHex = backgroundColorHex
    }
}

final class NativeSafeAreaTopSurfaceView: UIView {
    private let surface = UIView()
    var backgroundColorHex = "#000000" {
        didSet {
            surface.backgroundColor = UIColor(zgtHex: backgroundColorHex) ?? .black
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        surface.isUserInteractionEnabled = false
        surface.backgroundColor = .black
        addSubview(surface)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let topInset = window?.safeAreaInsets.top ?? safeAreaInsets.top
        surface.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topInset)
    }
}
