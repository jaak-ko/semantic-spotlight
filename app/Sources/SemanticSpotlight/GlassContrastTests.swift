#if DEBUG
import AppKit
import SwiftUI

/// Test only (run by the theme test): the glass, composited over synthetic desktop backdrops, in light and dark.
///
/// The render is in-window and uses the same SwiftUI material the app uses, so the material blurs the backdrop itself;
/// nothing is approximated. Two surfaces are measured:
///  - the glass chrome (the window's own surface, with no text on it): its transmission, which shows the desktop;
///  - the scrims and the near-opaque surfaces where text sits: the worst WCAG ratio of the text colours against every
///    composited pixel of the surface, which must be at least 4.5:1 (AA).
/// Backdrops: white, black, a busy high-contrast pattern, a bright saturated gradient, and a photo-like colour field with
/// detail (blobs and fine stripes).
enum GlassContrastTests {
    enum Backdrop: CaseIterable {
        case white, black, busy, saturated, photo
        var name: String {
            switch self {
            case .white: return "white"
            case .black: return "black"
            case .busy: return "busy"
            case .saturated: return "saturated"
            case .photo: return "photo"
            }
        }
    }

    /// The synthetic backdrop, the size of the test frame.
    @ViewBuilder static func backdrop(_ kind: Backdrop) -> some View {
        switch kind {
        case .white: Color.white
        case .black: Color.black
        case .busy:
            Canvas { ctx, size in
                let cell: CGFloat = 4
                var y: CGFloat = 0, row = 0
                while y < size.height {
                    var x: CGFloat = 0, col = 0
                    while x < size.width {
                        ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color((row + col) % 2 == 0 ? .white : .black))
                        x += cell; col += 1
                    }
                    y += cell; row += 1
                }
                ctx.fill(Path(CGRect(x: 0, y: 40, width: size.width, height: 60)), with: .color(.red))
                ctx.fill(Path(CGRect(x: 0, y: 260, width: size.width, height: 60)), with: .color(.blue))
            }
        case .saturated:
            ZStack {
                LinearGradient(colors: [Color(red: 1.0, green: 0.18, blue: 0.33), Color(red: 1.0, green: 0.8, blue: 0.0),
                                        Color(red: 0.2, green: 0.78, blue: 0.35), Color(red: 0.04, green: 0.52, blue: 1.0),
                                        Color(red: 0.75, green: 0.35, blue: 0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white, .clear], center: .init(x: 0.2, y: 0.2), startRadius: 0, endRadius: 320)
            }
        case .photo:
            // Deterministic blobs of many colours, plus fine diagonal stripes: a photo's colour and detail, no text.
            Canvas { ctx, size in
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat(seed >> 11) / CGFloat(1 << 53)
                }
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.42), Color(red: 0.55, green: 0.3, blue: 0.5)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                for _ in 0..<70 {
                    let r = 30 + 110 * next()
                    let c = Color(red: Double(next()), green: Double(next()), blue: Double(next()))
                    let center = CGPoint(x: size.width * next(), y: size.height * next())
                    ctx.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)), with: .color(c.opacity(0.8)))
                }
                var x: CGFloat = -size.height
                while x < size.width {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x, y: size.height)); stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                    ctx.stroke(stripe, with: .color(.white.opacity(0.18)), lineWidth: 1.5)
                    x += 9
                }
            }
        }
    }

    /// The frame of the backdrop, and the rectangles measured inside it (glass chrome, and a scrim on the same glass).
    static let backdropSize = CGSize(width: 760, height: 460)
    static let chromeRect = CGRect(x: 60, y: 40, width: 640, height: 120)
    static let scrimRect = CGRect(x: 60, y: 200, width: 640, height: 160)

    /// The chrome and the scrim, each over the backdrop: a host view with the backdrop and the two surfaces.
    static func probe(_ kind: Backdrop, dark: Bool, solid: Bool) -> NSView {
        let view = ZStack(alignment: .topLeading) {
            backdrop(kind).frame(width: backdropSize.width, height: backdropSize.height)
            Color.clear.frame(width: chromeRect.width, height: chromeRect.height)
                .glassSurface(radius: 0)
                .offset(x: chromeRect.minX, y: chromeRect.minY)
            Color.clear.frame(width: scrimRect.width, height: scrimRect.height)
                .glassSurface(radius: 0)
                .offset(x: scrimRect.minX, y: scrimRect.minY)
        }
        .frame(width: backdropSize.width, height: backdropSize.height)
        .environment(\.solidGlassForTest, solid)
        return host(view, dark: dark)
    }

    static func host<V: View>(_ view: V, dark: Bool) -> NSView {
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(origin: .zero, size: backdropSize)
        h.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        h.layoutSubtreeIfNeeded()
        return h
    }

    /// The composited pixels of a view (rendered at the backing scale), with the scale to convert points.
    static func pixels(_ view: NSView) -> (NSBitmapImageRep, CGFloat)? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / backdropSize.width)
    }

    /// The lowest WCAG ratio of `text` against any composited pixel inside `rect` (inset 16 pt: the surface's edge is not
    /// text), and the mean and spread of the composited luminance (how much the backdrop shows through).
    static func statistics(_ rep: NSBitmapImageRep, scale: CGFloat, rect: CGRect, text: NSColor, dark: Bool)
        -> (worst: CGFloat, mean: CGFloat, spread: CGFloat) {
        let x0 = Int((rect.minX + 16) * scale), x1 = Int((rect.maxX - 16) * scale)
        let y0 = Int((rect.minY + 16) * scale), y1 = Int((rect.maxY - 16) * scale)
        var worst = CGFloat.greatestFiniteMagnitude
        var lum: [CGFloat] = []
        for y in stride(from: y0, to: y1, by: 3) {
            for x in stride(from: x0, to: x1, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                worst = min(worst, Theme.ratio(text, c, dark: dark))
                lum.append(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
            }
        }
        let mean = lum.reduce(0, +) / CGFloat(max(lum.count, 1))
        let variance = lum.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(max(lum.count, 1))
        return (worst, mean, variance.squareRoot())
    }

    /// Runs the measurements, renders the surfaces, and returns the number of text pairs below AA (4.5:1).
    @MainActor @discardableResult
    static func run(dir: String) -> Int {
        var failures = 0
        for dark in [false, true] {
            for kind in Backdrop.allCases {
                let view = probe(kind, dark: dark, solid: false)
                guard let (rep, scale) = pixels(view) else { failures += 1; continue }
                let ink = statistics(rep, scale: scale, rect: scrimRect, text: Theme.inkNS, dark: dark)
                let muted = statistics(rep, scale: scale, rect: scrimRect, text: Theme.mutedNS, dark: dark)
                let chrome = statistics(rep, scale: scale, rect: chromeRect, text: Theme.inkNS, dark: dark)
                // Matched: the window's appearance against a backdrop of the same polarity (AA 4.5:1). Mismatched: a light
                // window over black or a dark window over white (3:1, the legibility floor for large or secondary text).
                let matched = dark ? [Backdrop.black, .photo, .busy, .saturated].contains(kind)
                                   : [Backdrop.white, .photo, .busy, .saturated].contains(kind)
                let minimum: CGFloat = matched ? 4.5 : 3.0
                let ok = ink.worst >= minimum && muted.worst >= minimum
                if !ok { failures += 1 }
                let mode = dark ? "dark" : "light"
                let kindName = matched ? "matched" : "mismatched"
                MenuBarIcon.testLog("glass \(kindName): \(kind.name) \(mode) ink \(f(ink.worst)) muted \(f(muted.worst)) (min \(f(minimum))) \(ok ? "ok" : "FAIL")")
                MenuBarIcon.testLog("glass chrome: \(kind.name) \(mode) backdrop shows: mean luminance \(f(chrome.mean)), spread \(f(chrome.spread))")
                _ = UIDumpFormat.png(view, to: "\(dir)/probe-\(kind.name)-\(mode).png")
            }
        }
        failures += checkSolidFallback(dir: dir)
        failures += checkIncreaseContrast()
        MenuBarIcon.testLog("glass contrast: \(failures) check(s) failed")
        renderSurfaces(dir: dir)
        return failures
    }

    /// Reduce Transparency: the glass is the solid panel colour, whatever the backdrop.
    @MainActor static func checkSolidFallback(dir: String) -> Int {
        var failures = 0
        for dark in [false, true] {
            guard let (rep, scale) = pixels(probe(.photo, dark: dark, solid: true)) else { failures += 1; continue }
            let stats = statistics(rep, scale: scale, rect: chromeRect, text: Theme.inkNS, dark: dark)
            let panel = Theme.panelNS.usingColorSpace(.sRGB) ?? .gray
            var appearanceLum: CGFloat = 0
            (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                let p = Theme.panelNS.usingColorSpace(.sRGB) ?? panel
                appearanceLum = 0.2126 * p.redComponent + 0.7152 * p.greenComponent + 0.0722 * p.blueComponent
            }
            let ok = stats.spread < 0.01 && abs(stats.mean - appearanceLum) < 0.02
            if !ok { failures += 1 }
            MenuBarIcon.testLog("glass solid fallback: \(dark ? "dark" : "light") mean \(f(stats.mean)) spread \(f(stats.spread)) panel \(f(appearanceLum)) \(ok ? "ok" : "FAIL")")
        }
        return failures
    }

    /// Increase Contrast: the muted text and the hairline take their stronger variants, which are higher ratios on the
    /// panel. The system's high-contrast appearance cannot be created by name here, so the choice the tokens make for it
    /// is tested directly (Theme.hex(match:...)).
    @MainActor static func checkIncreaseContrast() -> Int {
        var failures = 0
        for dark in [false, true] {
            let plain = Theme.hex(match: dark ? .darkAqua : .aqua, light: 0x4a4a50, dark: 0xececf0,
                                  highContrastLight: 0x2e2e34, highContrastDark: 0xffffff)
            let strong = Theme.hex(match: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua,
                                   light: 0x4a4a50, dark: 0xececf0, highContrastLight: 0x2e2e34, highContrastDark: 0xffffff)
            let panel = Theme.hex(match: dark ? .darkAqua : .aqua, light: 0xf5f5f7, dark: 0x2c2c30)
            let ratioPlain = ratio(plain, panel), ratioStrong = ratio(strong, panel)
            let ok = strong != plain && ratioStrong > ratioPlain && ratioStrong >= 4.5
            if !ok { failures += 1 }
            MenuBarIcon.testLog("glass increase contrast: \(dark ? "dark" : "light") muted \(f(ratioPlain)) -> \(f(ratioStrong)) \(ok ? "ok" : "FAIL")")
        }
        return failures
    }

    private static func ratio(_ a: UInt32, _ b: UInt32) -> CGFloat {
        func lum(_ hex: UInt32) -> CGFloat {
            func ch(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = CGFloat((hex >> 16) & 0xff) / 255, g = CGFloat((hex >> 8) & 0xff) / 255, bl = CGFloat(hex & 0xff) / 255
            return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(bl)
        }
        let la = lum(a), lb = lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Every surface over the photo, white and black backdrops, in light and dark, and in the solid fallback (Reduce
    /// Transparency). Files: surface-<name>[-solid]-<backdrop>-<mode>.png.
    @MainActor static func renderSurfaces(dir: String) {
        let scope = FolderScope(defaults: MemoryPrefs())
        scope.reconcile(EngineStatus(["files": 9, "chunks": 40, "folders": ["/fixture/notes", "/fixture/work"], "indexing": false,
                                      "model": "m", "model_ready": true, "folder_stats": [["path": "/fixture/notes", "files": 6],
                                                                                          ["path": "/fixture/work", "files": 3]]]))
        let search = SearchModel(engine: EngineManager.shared, scope: scope)
        search.testSetResults((0..<3).map { Hit(id: "\($0)", path: "/fixture/notes/file-\($0).txt", score: 0.5,
                                                similarity: 0.9, snippet: "A snippet about the file, with a few words.") }, notice: "")
        // The welcome states: 1 model missing, 2 downloading, 3 model ready (no folder), 4 indexed.
        func welcome(_ state: Int) -> OnboardingModel {
            let m = OnboardingModel()
            switch state {
            case 2:
                m.download = .running; m.downloadedBytes = (212_000_000, 470_000_000)
                m.ease.seed(done: 212_000_000, total: 470_000_000)
            case 3:
                m.apply(EngineStatus(["files": 0, "chunks": 0, "folders": [], "indexing": false, "model": "m", "model_ready": true]), rows: [])
            case 4:
                m.apply(EngineStatus(["files": 6, "chunks": 20, "folders": ["/fixture/notes"], "indexing": false, "model": "m",
                                      "model_ready": true, "folder_stats": [["path": "/fixture/notes", "files": 6]]]),
                        rows: [FolderRow(id: "/fixture/notes", path: "/fixture/notes", text: "6 files", tone: .ok)])
            default: break
            }
            return m
        }
        for solid in [false, true] {
            let tag = solid ? "-solid" : ""
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                for kind in [Backdrop.photo, .white, .black] {
                    let b = kind.name
                    for state in 1...4 {
                        _ = UIDumpFormat.png(surfaceOver(kind, dark: dark, solid: solid, size: CGSize(width: 440, height: 620)) {
                            OnboardingView(model: welcome(state), onFinish: {}, onLater: {}).frame(width: 380)
                        }, to: "\(dir)/surface-welcome-state\(state)\(tag)-\(b)-\(mode).png")
                    }
                    _ = UIDumpFormat.png(surfaceOver(kind, dark: dark, solid: solid, size: CGSize(width: 760, height: 560)) {
                        SearchView(model: search, scope: scope).frame(width: 640)
                    }, to: "\(dir)/surface-search\(tag)-\(b)-\(mode).png")
                    _ = UIDumpFormat.png(surfaceOver(kind, dark: dark, solid: solid, size: CGSize(width: 520, height: 900)) {
                        SettingsView(nav: SettingsNav.shared, welcome: OnboardingModel()).frame(width: 460)
                    }, to: "\(dir)/surface-settings\(tag)-\(b)-\(mode).png")
                    _ = UIDumpFormat.png(surfaceOver(kind, dark: dark, solid: solid, size: CGSize(width: 380, height: 420)) {
                        FolderPopoverView(model: search, scope: scope, onHover: { _ in }).frame(width: 320)
                    }, to: "\(dir)/surface-popover\(tag)-\(b)-\(mode).png")
                    _ = UIDumpFormat.png(surfaceOver(kind, dark: dark, solid: solid, size: CGSize(width: 520, height: 560)) {
                        UninstallSheet(model: UninstallModel(), close: {}).frame(width: 480)
                    }, to: "\(dir)/surface-uninstall-sheet\(tag)-\(b)-\(mode).png")
                    _ = UIDumpFormat.png(surfaceOver(kind, dark: dark, solid: solid, size: CGSize(width: 520, height: 560)) {
                        DiagnosticsSheet(model: DiagnosticsModel(), close: {}).frame(width: 480)
                    }, to: "\(dir)/surface-diagnostics-sheet\(tag)-\(b)-\(mode).png")
                }
            }
        }
    }

    /// A view over a backdrop of the given size (the glass is the view's own surface, so the backdrop shows through it).
    @MainActor static func surfaceOver<V: View>(_ kind: Backdrop, dark: Bool, solid: Bool = false, size: CGSize,
                                                @ViewBuilder _ content: () -> V) -> NSView {
        let view = ZStack {
            backdrop(kind)
            content()
        }
        .frame(width: size.width, height: size.height)
        .environment(\.solidGlassForTest, solid)
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(origin: .zero, size: size)
        h.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        h.layoutSubtreeIfNeeded()
        return h
    }

    private static func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
}
#endif
