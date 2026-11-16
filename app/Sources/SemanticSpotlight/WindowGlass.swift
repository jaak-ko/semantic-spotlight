import AppKit

/// The glass of a whole window, as AppKit views under the content: a behind-window blur (NSVisualEffectView) and the
/// tint over it. Both sit in the window's frame view, below the content, and are sized by autoresizing to the whole frame
/// view, titlebar included. AppKit resizes them in the same pass as the window's frame, so no part of the window is ever
/// uncovered while the frame animates (the SwiftUI glass was re-laid out with the content and could drop out of the strip).
/// Reduce Transparency: the blur is replaced by the solid panel colour.
enum WindowGlass {
    static let blurID = NSUserInterfaceItemIdentifier("windowGlass.blur")
    static let tintID = NSUserInterfaceItemIdentifier("windowGlass.tint")

    static func install(on window: NSWindow) {
        guard let frameView = window.contentView?.superview, !frameView.subviews.contains(where: { $0.identifier == blurID }) else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let base: NSView
        if reduce {
            base = TintView(color: { Theme.panelNS }, solid: true)
        } else {
            let blur = NSVisualEffectView()
            blur.material = .underWindowBackground
            blurringMode(blur)
            base = blur
        }
        base.identifier = blurID
        base.frame = frameView.bounds
        base.autoresizingMask = [.width, .height]
        let tint = TintView(color: { Theme.glassTintNS }, solid: false)
        tint.identifier = tintID
        tint.frame = frameView.bounds
        tint.autoresizingMask = [.width, .height]
        // Bottom of the stack: the blur, then the tint, then the window's content on top of both.
        frameView.addSubview(base, positioned: .below, relativeTo: nil)
        frameView.addSubview(tint, positioned: .above, relativeTo: base)
    }

    private static func blurringMode(_ blur: NSVisualEffectView) {
        blur.blendingMode = .behindWindow
        blur.state = .active
    }
}

/// A view that paints one dynamic colour (the theme's tokens resolve for the current appearance).
final class TintView: NSView {
    private let color: () -> NSColor
    private let solid: Bool

    init(color: @escaping () -> NSColor, solid: Bool) {
        self.color = color
        self.solid = solid
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color().cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
