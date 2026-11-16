import AppKit
import SwiftUI

/// Button roles of the one button system. Every button of the app is a ThemeButton; capsules only.
///  - primary: solid orange capsule, white text. One per view.
///  - secondary: grey wash capsule, ink text.
///  - tertiary: text only, accent orange. tertiaryInk: text only, ink. quiet: text only, secondary text colour, 13 pt
///    medium at any size (a neutral action such as Later).
///  - destructive: red wash capsule, red text. destructiveSolid: solid red, white text (the final confirm only).
enum ThemeRole: CaseIterable { case primary, secondary, tertiary, tertiaryInk, quiet, destructive, destructiveSolid }

/// Sizes of the one button system. Regular is 38 pt tall (full width in content areas); compact is 24 pt (pills, the
/// scope chip, row actions).
enum ThemeSize: CaseIterable { case regular, compact }

/// The one button of the app. Hover strengthens the fill, press strengthens it further and scales to 0.98, disabled is
/// 45% opacity (still legible, never dashed). The hit area is at least 28 pt tall. The keyboard focus ring is drawn here.
struct ThemeButton<Label: View>: View {
    let role: ThemeRole
    let size: ThemeSize
    var fullWidth = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    /// Told when the keyboard focus moves onto or off the button (a row's Remove reveals itself for the keyboard).
    var focusChanged: ((Bool) -> Void)? = nil
    @FocusState private var focused: Bool
    @State private var hovering = false
    @ObservedObject private var keyboard = KeyboardFocus.shared
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(ThemeButtonStyle(role: role, size: size, fullWidth: fullWidth, hovering: hovering))
        .focusEffectDisabled()   // the system's rectangular focus ring is replaced by the capsule ring below
        .focused($focused)
        .themeFocusRing(focused && isEnabled && keyboard.active)
        .onChange(of: focused) { _, now in focusChanged?(now) }
        .onHover { inside in
            hovering = inside
            if inside, isEnabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension ThemeButton where Label == ThemeButtonLabel {
    /// A text button, with an optional leading SF Symbol (15 pt regular, 12 pt compact, 8 pt gap).
    init(_ title: String, systemImage: String? = nil, role: ThemeRole, size: ThemeSize = .regular,
         fullWidth: Bool = false, focusChanged: ((Bool) -> Void)? = nil, action: @escaping () -> Void) {
        self.init(role: role, size: size, fullWidth: fullWidth, action: action, label: {
            ThemeButtonLabel(title: title, systemImage: systemImage, size: size)
        }, focusChanged: focusChanged)
    }
}

/// The label of a text ThemeButton: the title with an optional leading symbol.
struct ThemeButtonLabel: View {
    let title: String
    let systemImage: String?
    let size: ThemeSize

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size == .regular ? 15 : 12, weight: .medium))
            }
            Text(title)
        }
    }
}

/// The button's look for its role, size and state. Used only by ThemeButton; the source scan test enforces that.
struct ThemeButtonStyle: ButtonStyle {
    let role: ThemeRole
    let size: ThemeSize
    var fullWidth = false
    var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        ThemeButtonFace(role: role, size: size, fullWidth: fullWidth, hovering: hovering, pressed: configuration.isPressed) {
            configuration.label
        }
    }
}

/// The face of a button in a given state: the one place where the role, size, fill, text and state visuals are drawn.
/// The style passes the live hover and press; the button gallery passes them directly.
struct ThemeButtonFace<Label: View>: View {
    let role: ThemeRole
    let size: ThemeSize
    var fullWidth = false
    var hovering = false
    var pressed = false
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var isEnabled

    var height: CGFloat { size == .regular ? 38 : 24 }

    var body: some View {
        label()
            .lineLimit(1)                 // a button label never wraps: the button grows to fit it
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: role == .quiet || size == .regular ? 13 : 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .regular ? 16 : 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height, maxHeight: height)
            .background(Capsule().fill(fill))
            .frame(minHeight: max(height, 28), alignment: .center)   // the hit area is at least 28 pt tall
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(pressed && isEnabled ? 0.98 : 1)
    }

    private var foreground: Color {
        switch role {
        case .primary, .destructiveSolid: return Theme.onAccent
        case .secondary, .tertiaryInk: return Theme.ink
        case .quiet: return Theme.muted
        case .tertiary: return Theme.accent
        case .destructive: return Theme.danger
        }
    }

    private var fill: Color {
        switch role {
        case .primary: return pressed ? Theme.accentFillPressed : (hovering ? Theme.accentFillHover : Theme.accentFill)
        case .destructiveSolid: return pressed ? Theme.dangerSolidPressed : (hovering ? Theme.dangerSolidHover : Theme.dangerSolid)
        case .secondary: return pressed ? Theme.washPressed : (hovering ? Theme.washHover : Theme.wash)
        case .destructive: return pressed ? Theme.dangerWashPressed : (hovering ? Theme.dangerWashHover : Theme.dangerWash)
        case .tertiary, .tertiaryInk, .quiet: return pressed || hovering ? Theme.washHover : .clear
        }
    }
}

/// A context-menu item (not a button on the window): lives here so the one button file is the only place a Button is made.
@ViewBuilder func copyMenuItem(_ title: String, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
}

extension View {
    /// The keyboard focus ring of a button: a 2 pt ring on the capsule's own outline, outset 2 pt, accent at 60%. It is
    /// shown only while the keyboard drives focus (see KeyboardFocus). Shared by ThemeButton and the gallery.
    func themeFocusRing(_ on: Bool) -> some View {
        overlay {
            if on { Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 2).padding(-2) }
        }
    }
}

/// Whether the keyboard is moving focus: true after Tab or an arrow key, false after a click. The focus ring shows only
/// then, so a window that opens with a button already focused draws no ring until the user presses Tab.
final class KeyboardFocus: ObservableObject {
    static let shared = KeyboardFocus()
    @Published private(set) var active = false
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            if event.type == .keyDown {
                if [48, 123, 124, 125, 126].contains(event.keyCode) { KeyboardFocus.shared.set(true) }
            } else {
                KeyboardFocus.shared.set(false)
            }
            return event
        }
    }

    private func set(_ on: Bool) { if active != on { active = on } }
}
