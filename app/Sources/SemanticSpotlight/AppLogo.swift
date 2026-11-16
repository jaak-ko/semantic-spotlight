import AppKit
import SwiftUI

/// The app's logo: the real icon asset (AppIcon.icns, the same file the bundle ships), drawn from its largest
/// representation at the size asked for. Plain: no tint, blend, vibrancy or opacity, the same in light and dark.
enum AppLogo {
    /// The icon asset: from the bundle in a built app; in debug and test runs (the test binary has no bundle icon), from
    /// the source tree. Release builds never read the source tree.
    static let asset: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            return image
        }
#if DEBUG
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/icon/AppIcon.icns")
        return NSImage(contentsOf: source)
#else
        return nil
#endif
    }()

    /// The asset drawn at `points` square, from its largest representation.
    static func image(points: CGFloat) -> NSImage? {
        guard let asset else { return nil }
        let largest = asset.representations.max { $0.pixelsWide < $1.pixelsWide }
        return NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            if let largest {
                largest.draw(in: rect)
            } else {
                asset.draw(in: rect)
            }
            return true
        }
    }

    /// The welcome page's logo: 64 pt.
    static let header: NSImage? = image(points: 64)
}

/// The logo as a plain image: no tint, no blend, no opacity, in both appearances.
struct AppLogoView: View {
    var body: some View {
        if let image = AppLogo.header {
            Image(nsImage: image)
                .renderingMode(.original)
                .interpolation(.high)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
                .layoutProbe("welcome.logo")
        }
    }
}
