#if DEBUG
import AppKit

/// Test only (run by the theme test): the welcome's logo is the app's icon asset, drawn from its largest representation at
/// 64 pt. The rendered 64 pt image has the same size and the same pixels (a checksum) as the asset drawn the same way.
enum AppLogoTests {
    /// FNV-1a over the bitmap's bytes.
    static func checksum(_ rep: NSBitmapImageRep) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        guard let bytes = rep.bitmapData else { return 0 }
        for i in 0..<(rep.bytesPerRow * rep.pixelsHigh) {
            hash = (hash ^ UInt64(bytes[i])) &* 0x100000001b3
        }
        return hash
    }

    static func render(_ image: NSImage, points: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: points, pixelsHigh: points, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 32) else { return nil }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: points, height: points).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("app logo: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        check("the icon asset loads (the bundle's AppIcon.icns, or the source tree in tests)", AppLogo.asset != nil)
        guard let header = AppLogo.header, let asset = AppLogo.asset else { return failures + 1 }
        check("the welcome logo is 64 pt", header.size == NSSize(width: 64, height: 64), "\(header.size)")
        // The same drawing, done independently: the asset's largest representation, at 64 points.
        let largest = asset.representations.max { $0.pixelsWide < $1.pixelsWide }
        let reference = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            (largest ?? asset.representations.first)?.draw(in: rect)
            return true
        }
        guard let a = render(header, points: 64), let b = render(reference, points: 64) else {
            check("the logo renders", false)
            return failures + 1
        }
        check("the rendered 64 pt logo has the asset's pixels (checksum)", checksum(a) == checksum(b) && checksum(a) != 0,
              String(format: "%016llx vs %016llx", checksum(a), checksum(b)))
        check("the logo is drawn from the largest representation", (largest?.pixelsWide ?? 0) >= 256,
              "largest \(largest?.pixelsWide ?? 0) px")
        // The welcome page shows that logo: its frame on the page is 64 pt.
        let page = ButtonRowLayoutTests.layout(OnboardingView(model: OnboardingModel(), onFinish: {}, onLater: {}), dark: false)
        let shown = page["welcome.logo"]?.size ?? .zero
        check("the welcome page shows the logo at 64 pt", shown == NSSize(width: 64, height: 64), "\(shown)")
        return failures
    }
}
#endif
