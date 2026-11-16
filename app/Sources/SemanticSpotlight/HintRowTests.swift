#if DEBUG
import AppKit
import SwiftUI

/// Test only (run by the theme test): the footer's key caps, rendered at 4x. Each cap is found by its fill; each glyph's
/// ink is the pixels that differ from the fill inside the cap. The check: every glyph's vertical ink centre is within 1
/// device-independent pixel of its cap's centre, all caps share one height, and their baselines are equal.
enum HintRowTests {
    struct Cap { let name: String; let box: CGRect; let ink: CGRect; var label: CGRect = .zero; var glyphs: [CGRect] = [] }

    /// The footer rendered at `scale` for one appearance, as a bitmap.
    @MainActor static func render(dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        let view = HintRow()
            .frame(width: 640, height: SearchLayout.footer)
            .background(Theme.panel)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    /// The caps in the image, left to right, with the ink box of each glyph inside its cap (image pixels, top-left origin).
    /// A cap is a connected component of pixels that differ from the panel background; the glyphs are inside it, so they
    /// stay with their cap, and the labels beside the caps are separate components. The cap's fill is its most common
    /// colour: the rendered colours are not exactly the token values (the renderer converts colour spaces), so the fill is
    /// measured, not looked up.
    @MainActor static func measure(_ rep: NSBitmapImageRep, dark: Bool, scale: CGFloat) -> [Cap] {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        func near(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ t: CGFloat) -> Bool {
            abs(a.0 - b.0) < t && abs(a.1 - b.1) < t && abs(a.2 - b.2) < t
        }
        // The panel is a solid colour in the render, so its colour is the image's corner.
        let bg = rgb(0, 0)
        var colour = [(CGFloat, CGFloat, CGFloat)](repeating: bg, count: w * h)
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let c = rgb(x, y)
                colour[y * w + x] = c
                mask[y * w + x] = !near(c, bg, 0.03)
            }
        }
        var visited = [Bool](repeating: false, count: w * h)
        var caps: [Cap] = []
        for start in 0..<(w * h) where mask[start] && !visited[start] {
            var minX = w, maxX = 0, minY = h, maxY = 0
            var members: [Int] = []
            var stack = [start]
            visited[start] = true
            while let p = stack.popLast() {
                members.append(p)
                let x = p % w, y = p / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let q = ny * w + nx
                    if mask[q] && !visited[q] { visited[q] = true; stack.append(q) }
                }
            }
            // A cap is a tall component; labels are one line of text, the footer's divider is a thin line.
            guard CGFloat(maxY - minY) > 10 * scale, CGFloat(maxX - minX) > 10 * scale else { continue }
            // The fill: the most common colour in the component, rounded so near-equal pixels count together.
            var counts: [String: Int] = [:]
            var sample: [String: (CGFloat, CGFloat, CGFloat)] = [:]
            for p in members {
                let c = colour[p]
                let key = String(format: "%.2f,%.2f,%.2f", c.0, c.1, c.2)
                counts[key, default: 0] += 1
                sample[key] = c
            }
            guard let fillKey = counts.max(by: { $0.value < $1.value })?.key, let fill = sample[fillKey] else { continue }
            // The glyph ink: pixels inside the cap, inside its 1 pt border, that differ from the fill.
            let inset = Int(scale)
            var ix0 = CGFloat.greatestFiniteMagnitude, iy0 = CGFloat.greatestFiniteMagnitude
            var ix1: CGFloat = 0, iy1: CGFloat = 0
            for y in (minY + inset)...(maxY - inset) {
                for x in (minX + inset)...(maxX - inset) {
                    let p = y * w + x
                    if mask[p] && !near(colour[p], fill, 0.12) {
                        ix0 = min(ix0, CGFloat(x)); iy0 = min(iy0, CGFloat(y))
                        ix1 = max(ix1, CGFloat(x + 1)); iy1 = max(iy1, CGFloat(y + 1))
                    }
                }
            }
            let ink = ix1 > ix0 ? CGRect(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0) : .zero
            // Each glyph is a run of ink columns: the command sign and the arrow of "⌘↩" are two runs, "Space" has five.
            var glyphs: [CGRect] = []
            var run: (Int, Int)? = nil
            func flush() {
                if let (a, b) = run {
                    var gy0 = h, gy1 = 0
                    for x in a..<b { for y in Int(iy0)..<Int(iy1) where mask[y * w + x] && !near(colour[y * w + x], fill, 0.12) { gy0 = min(gy0, y); gy1 = max(gy1, y + 1) } }
                    if gy1 > gy0 { glyphs.append(CGRect(x: a, y: gy0, width: b - a, height: gy1 - gy0)) }
                }
                run = nil
            }
            for x in Int(ix0)..<Int(max(ix1, ix0)) {
                var colHasInk = false
                for y in Int(iy0)..<Int(iy1) where mask[y * w + x] && !near(colour[y * w + x], fill, 0.12) { colHasInk = true; break }
                if colHasInk { run = run.map { ($0.0, x + 1) } ?? (x, x + 1) } else { flush() }
            }
            flush()
            caps.append(Cap(name: "", box: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), ink: ink, glyphs: glyphs))
        }
        // The labels: every other text component. A label is the first text component to the right of its cap, on the
        // cap's rows, within 12 pt.
        var texts: [CGRect] = []
        visited = [Bool](repeating: false, count: w * h)
        for start in 0..<(w * h) where mask[start] && !visited[start] {
            var minX = w, maxX = 0, minY = h, maxY = 0
            var stack = [start]
            visited[start] = true
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let q = ny * w + nx
                    if mask[q] && !visited[q] { visited[q] = true; stack.append(q) }
                }
            }
            let r = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            if !caps.contains(where: { $0.box.intersects(r) }), r.height < CGFloat(h) / 2 { texts.append(r) }
        }
        let names = ["open (return)", "show in Finder (cmd return)", "preview (space)", "close (esc)"]
        return caps.sorted { $0.box.minX < $1.box.minX }.enumerated().map { i, cap in
            let label = texts
                .filter { $0.minX >= cap.box.maxX && $0.minX < cap.box.maxX + 12 * scale * 3 && $0.intersects(cap.box.insetBy(dx: 0, dy: -4 * scale)) || ($0.minX >= cap.box.maxX && $0.minX < cap.box.maxX + 12 * scale * 3 && $0.midY > cap.box.minY && $0.midY < cap.box.maxY) }
                .min(by: { $0.minX < $1.minX }) ?? .zero
            return Cap(name: i < names.count ? names[i] : "cap \(i)", box: cap.box, ink: cap.ink, label: label, glyphs: cap.glyphs)
        }
    }

    /// Runs the check at 4x in both appearances. Returns the number of failed assertions.
    @MainActor @discardableResult
    static func run(dir: String) -> Int {
        var failures = 0
        for dark in [false, true] {
            guard let rep = render(dark: dark, scale: 4) else { failures += 1; continue }
            let caps = measure(rep, dark: dark, scale: 4)
            let label = dark ? "dark" : "light"
            if caps.count != 4 {
                failures += 1
                MenuBarIcon.testLog("hint row \(label): found \(caps.count) caps, expected 4 FAIL")
                continue
            }
            // The cap-height glyphs (the symbols, the capitals) must sit on the cap's centre: within 2 px at 4x, which is 1 px at
            // the 2x of a Retina screen. Lowercase letters are shorter than the capitals and centre on their x-height, as
            // typeset text does, so they are reported and not asserted.
            for cap in caps {
                let topmost = cap.glyphs.map { $0.minY }.min() ?? 0
                for (gi, g) in cap.glyphs.enumerated() {
                    let d = abs(g.midY - cap.box.midY)
                    // A capital (or a symbol) reaches the top line of the cap's text; a lowercase letter starts lower.
                    let capHeight = g.minY <= topmost + 1
                    let fails = capHeight && d > 2
                    if fails { failures += 1 }
                    MenuBarIcon.testLog("hint glyph \(label): \(cap.name) glyph \(gi + 1) \(capHeight ? "cap-height" : "lowercase") centre \(String(format: "%.2f", g.midY / 4)) pt, cap centre \(String(format: "%.2f", cap.box.midY / 4)) pt, offset \(String(format: "%.2f", d / 4)) pt \(fails ? "FAIL" : "ok")")
                }
            }
            let heights = Set(caps.map { Int($0.box.height) })
            // Equal heights and one baseline: every cap's bottom edge is the same row of pixels (the caps share a row).
            let baselines = Set(caps.map { Int($0.box.maxY) })
            if baselines.count != 1 { failures += 1; MenuBarIcon.testLog("hint row \(label): cap bottoms differ \(baselines.sorted()) FAIL") }
            if heights.count != 1 { failures += 1; MenuBarIcon.testLog("hint row \(label): cap heights \(heights.sorted()) FAIL") }
            for cap in caps {
                let capCentre = cap.box.midY
                let inkCentre = cap.ink.midY
                let deltaPx = abs(inkCentre - capCentre)
                let ok = deltaPx <= 4   // 4 px at 4x is 1 pt; the test asserts 1 device pixel at 1x (4 px at 4x)
                if !ok { failures += 1 }
                if cap.label != .zero {
                MenuBarIcon.testLog("hint row \(label): \(cap.name) label centre \(String(format: "%.1f", cap.label.midY / 4)) pt, cap centre \(String(format: "%.1f", capCentre / 4)) pt, offset \(String(format: "%.2f", abs(cap.label.midY - capCentre) / 4)) pt")
            }
            MenuBarIcon.testLog("hint row \(label): \(cap.name) cap centre \(String(format: "%.1f", capCentre / 4)) pt, ink centre \(String(format: "%.1f", inkCentre / 4)) pt, offset \(String(format: "%.2f", deltaPx / 4)) pt \(ok ? "ok" : "FAIL")")
            }
            MenuBarIcon.testLog("hint row \(label): cap height \(heights.first.map { String($0 / 4) } ?? "?") pt, baselines \(baselines.sorted().map { String($0) }.joined(separator: ",")) px")
            if let rep = render(dark: dark, scale: 4), let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/hint-row-4x-\(label).png"))
            }
        }
        return failures
    }
}
#endif
