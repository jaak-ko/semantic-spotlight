import AppKit
import SwiftUI

/// The brand tokens, in one place. Every token is dynamic: light and dark follow the system appearance, and Increase
/// Contrast makes the hairlines and the muted text stronger. Surfaces are system glass (see `GlassSurface`); these
/// solid values are the fallback under Reduce Transparency and the reference for the contrast tests. Orange is the one
/// accent; green marks only done states; red only destructive actions.
enum Theme {
    /// A dynamic colour from a light and a dark hex value, with a stronger variant for Increase Contrast.
    private static func token(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil,
                              highContrastDark: UInt32? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                    .accessibilityHighContrastDarkAqua])
            return colour(hex: hex(match: match, light: light, dark: dark, highContrastLight: highContrastLight,
                                   highContrastDark: highContrastDark))
        }
    }

    /// A dynamic colour from a hex value and an alpha, light and dark.
    private static func alphaToken(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                     .accessibilityHighContrastDarkAqua]).map {
                $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            let (hex, alpha) = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
    }

    /// The hex value for the matched appearance. Separate from the dynamic colour so the choice is testable (the
    /// high-contrast appearances cannot be created by name in a headless test).
    static func hex(match: NSAppearance.Name?, light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil,
                    highContrastDark: UInt32? = nil) -> UInt32 {
        let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let highContrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        if highContrast, isDark, let v = highContrastDark { return v }
        if highContrast, !isDark, let v = highContrastLight { return v }
        return isDark ? dark : light
    }

    private static func colour(hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    /// The glass's tint: the panel colour over the material. Measured with GlassContrastTests, text directly on the glass
    /// passes WCAG AA (4.5:1 for the primary and the muted text) over every worst-case backdrop only from 90%: at 85% the
    /// muted text on dark glass over white falls to 4.43:1, and at 35-50% the light and dark extremes fail (1.6 to 4.2:1).
    /// Muted text over black needs about 88% opacity to reach 4.5:1 on any light surface, so a translucent glass cannot carry
    /// it at lower tints.
    static let glassTintAlpha: CGFloat = 0.58
    static let glassTintNS: NSColor = tint(alpha: glassTintAlpha)

    /// The panel colour at an alpha: light and dark, as the tokens.
    private static func tint(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                    .accessibilityHighContrastDarkAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let hex: UInt32 = isDark ? 0x2c2c30 : 0xf5f5f7
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
    }

    // Text
    static let inkNS = token(light: 0x1d1d1f, dark: 0xf5f5f7)                  // primary text
    static let mutedNS = token(light: 0x4a4a50, dark: 0xececf0,                // secondary text
                               highContrastLight: 0x2e2e34, highContrastDark: 0xffffff)
    // Surfaces (solid: the Reduce Transparency fallback; the glass material sits on top of the desktop otherwise)
    static let panelNS = token(light: 0xf5f5f7, dark: 0x2c2c30)                // window and panel surface
    static let chipNS = token(light: 0xefeff1, dark: 0x3d3d41)                 // tiles, key caps, the scope chip
    static let selectedNS = token(light: 0xe4e4e7, dark: 0x434347)             // the selected result row
    static let edgeNS = token(light: 0xd6d6da, dark: 0x48484c,                 // 0.5 pt hairlines (decorative)
                              highContrastLight: 0x9a9aa0, highContrastDark: 0x7a7a80)
    static let rimNS = token(light: 0xffffff, dark: 0x5a5a5e)                  // the 1 pt inner top highlight
    // Accent and states
    static let accentNS = token(light: 0xc2410c, dark: 0xff7a45)               // the one accent: actions, selection
    static let onAccentNS = token(light: 0xffffff, dark: 0xffffff)             // text on a solid button (AA on the fills)
    /// The solid button fills: #C2410C in both appearances (white text 5.2:1 on it); hover lighter, press darker.
    static let accentFillNS = token(light: 0xc2410c, dark: 0xc2410c)
    static let accentFillHoverNS = token(light: 0xc8460f, dark: 0xc8460f)
    static let accentFillPressedNS = token(light: 0xa83a0a, dark: 0xa83a0a)
    static let dangerSolidNS = token(light: 0xa8321a, dark: 0xa8321a)
    static let dangerSolidHoverNS = token(light: 0xb83b22, dark: 0xb83b22)
    static let dangerSolidPressedNS = token(light: 0x962b16, dark: 0x962b16)
    /// The grey wash of secondary and compact buttons: the system's secondary fill, over the glass.
    static let washNS = alphaToken(light: (0x787880, 0.16), dark: (0x787880, 0.36))
    static let washHoverNS = alphaToken(light: (0x787880, 0.24), dark: (0x787880, 0.46))
    static let washPressedNS = alphaToken(light: (0x787880, 0.32), dark: (0x787880, 0.56))
    /// The red wash of destructive buttons.
    static let dangerWashNS = alphaToken(light: (0xb42318, 0.12), dark: (0xff7a60, 0.20))
    static let dangerWashHoverNS = alphaToken(light: (0xb42318, 0.18), dark: (0xff7a60, 0.28))
    static let dangerWashPressedNS = alphaToken(light: (0xb42318, 0.24), dark: (0xff7a60, 0.36))
    static let successNS = token(light: 0x2f7d3a, dark: 0x5fbf6f)              // done marks only
    static let warningNS = token(light: 0x9a5200, dark: 0xf2b45c)              // indexing and warnings (icons: AA for UI)
    static let dangerNS = token(light: 0xa8321a, dark: 0xff9a7a,               // destructive only
                                highContrastLight: 0x8a2412, highContrastDark: 0xffb8a3)

    static var panel: Color { Color(nsColor: panelNS) }
    static var ink: Color { Color(nsColor: inkNS) }
    static var muted: Color { Color(nsColor: mutedNS) }
    static var chip: Color { Color(nsColor: chipNS) }
    static var selected: Color { Color(nsColor: selectedNS) }
    static var edge: Color { Color(nsColor: edgeNS) }
    static var rim: Color { Color(nsColor: rimNS) }
    static var accent: Color { Color(nsColor: accentNS) }
    static var onAccent: Color { Color(nsColor: onAccentNS) }
    static var accentFill: Color { Color(nsColor: accentFillNS) }
    static var accentFillHover: Color { Color(nsColor: accentFillHoverNS) }
    static var accentFillPressed: Color { Color(nsColor: accentFillPressedNS) }
    static var dangerSolid: Color { Color(nsColor: dangerSolidNS) }
    static var dangerSolidHover: Color { Color(nsColor: dangerSolidHoverNS) }
    static var dangerSolidPressed: Color { Color(nsColor: dangerSolidPressedNS) }
    static var wash: Color { Color(nsColor: washNS) }
    static var washHover: Color { Color(nsColor: washHoverNS) }
    static var washPressed: Color { Color(nsColor: washPressedNS) }
    static var dangerWash: Color { Color(nsColor: dangerWashNS) }
    static var dangerWashHover: Color { Color(nsColor: dangerWashHoverNS) }
    static var dangerWashPressed: Color { Color(nsColor: dangerWashPressedNS) }
    static var success: Color { Color(nsColor: successNS) }
    static var danger: Color { Color(nsColor: dangerNS) }
    static var warning: Color { Color(nsColor: warningNS) }

    /// The text colour pairs the surfaces use, for the contrast test: (text, background, minimum ratio).
    static var contrastPairs: [(name: String, text: NSColor, background: NSColor, minimum: CGFloat)] {
        [
            ("primary text on panel", inkNS, panelNS, 4.5),
            ("muted text on panel", mutedNS, panelNS, 4.5),
            ("accent text on panel (tertiary)", accentNS, panelNS, 4.5),
            ("success text on panel", successNS, panelNS, 4.5),
            ("danger text on panel", dangerNS, panelNS, 4.5),
            ("primary text on the grey wash (secondary button)", inkNS, washOverPanelNS, 4.5),
            ("muted text on the grey wash", mutedNS, washOverPanelNS, 4.5),
            ("danger text on the red wash (destructive button)", dangerNS, dangerWashOverPanelNS, 4.5),
            ("white on the solid orange fill (primary button)", onAccentNS, accentFillNS, 4.5),
            ("white on the orange hover fill", onAccentNS, accentFillHoverNS, 4.5),
            ("white on the orange pressed fill", onAccentNS, accentFillPressedNS, 4.5),
            ("white on the solid red (final confirm)", onAccentNS, dangerSolidNS, 4.5),
            ("accent on panel (UI)", accentNS, panelNS, 3.0),
            ("warning icon on panel (UI)", warningNS, panelNS, 3.0),
            ("edge hairline (decorative, reported)", edgeNS, panelNS, 0),
        ]
    }

    /// The grey wash and the red wash composited over the panel (light and dark), as opaque colours for the contrast test.
    /// The composites are the wash alpha over the panel colour: 0.16 grey over #f5f5f7, 0.36 grey over #2c2c30 (dark).
    static let washOverPanelNS = token(light: 0xe0e0e4, dark: 0x474750)
    static let dangerWashOverPanelNS = token(light: 0xede1dc, dark: 0x563c3a)

    /// The WCAG contrast ratio of two colours, resolved in the given appearance.
    static func ratio(_ a: NSColor, _ b: NSColor, dark: Bool) -> CGFloat {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var la: CGFloat = 0, lb: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            la = luminance(a.usingColorSpace(.sRGB) ?? a)
            lb = luminance(b.usingColorSpace(.sRGB) ?? b)
        }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ c: NSColor) -> CGFloat {
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
}

/// The one glass implementation of the app, for every surface: a window (radius 0: it fills the whole window, under the
/// transparent titlebar, and the window draws the corners), a panel or popover (its radius), and a sheet (its radius).
/// The fill is the system's material (it adapts to the wallpaper and the appearance) under the glass tint. Panels and
/// popovers have a 0.5 pt edge and a 1 pt inner top highlight. Under Reduce Transparency, and in the test renders that ask
/// for it, the fill is the solid panel colour instead.
struct GlassSurface: ViewModifier {
    /// 0 is the whole window; any other value is a panel, popover or sheet of that corner radius.
    var radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if DEBUG
    @Environment(\.solidGlassForTest) private var solidForTest
    #endif

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if radius == 0 {
            // A window: no clip at all. A clip would be the content's frame, which starts below the titlebar, and would cut
            // off the content that sits under the transparent titlebar.
            content
                .background { fill(shape).ignoresSafeArea() }
        } else {
            content
                .background { fill(shape) }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(Theme.edge, lineWidth: 0.5)
                    shape.strokeBorder(Theme.rim.opacity(0.85), lineWidth: 1)
                        .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
                }
        }
    }

    @ViewBuilder private func fill(_ shape: RoundedRectangle) -> some View {
        if solid {
            shape.fill(Theme.panel)
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(nsColor: Theme.glassTintNS))
            }
        }
    }

    private var solid: Bool {
        #if DEBUG
        return reduceTransparency || solidForTest
        #else
        return reduceTransparency
        #endif
    }
}

#if DEBUG
private struct SolidGlassKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Test only: draws the solid fallback as if Reduce Transparency were on (the renders check both).
    var solidGlassForTest: Bool {
        get { self[SolidGlassKey.self] }
        set { self[SolidGlassKey.self] = newValue }
    }
}
#endif

extension View {
    /// The app's glass. radius 0 for a window, the surface's corner radius otherwise.
    func glassSurface(radius: CGFloat) -> some View { modifier(GlassSurface(radius: radius)) }
}

/// A hairline divider: 0.5 point, the brand colour.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.edge).frame(height: 0.5)
    }
}

/// A key cap for a shortcut: the key in a small rounded chip with a hairline border. The symbol keys are SF Symbols in
/// fixed slots (the text glyphs come from a fallback font whose arrow sat high in the cap); every cap has the same height,
/// and its content is centred by the layout, so the glyph centres match the caps' centres (HintRowTests measures them).
struct KeyCap: View {
    let key: String

    var body: some View {
        content
            .frame(height: 16)
            .padding(.horizontal, 5)   // key cap inner width: the hint-row measurement is set for 5 (not on the 4/8 scale, on purpose)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.chip))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.edge, lineWidth: 0.5))
    }

    @ViewBuilder private var content: some View {
        switch key {
        case "↩":
            symbol("arrow.turn.down.left")
        case "⌘↩":
            HStack(spacing: 1) {
                symbol("command")
                symbol("arrow.turn.down.left")
            }
        default:
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.ink)
    }
}
