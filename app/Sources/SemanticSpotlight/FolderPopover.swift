import AppKit
import SwiftUI

/// The scope chip at the right of the search panel's top row: "All folders", or "2/3 folders" when some are left out.
/// A compact secondary ThemeButton of fixed width. Hover, click and focus all open the folder list (the owner decides how).
struct FolderScopeChip: View {
    @ObservedObject var scope: FolderScope
    let focused: Bool
    let open: Bool
    let onHover: (Bool) -> Void
    let onClick: () -> Void

    var body: some View {
        let title = scope.narrowed ? "\(scope.badge) folders" : "All folders"
        ThemeButton(role: .secondary, size: .compact, action: onClick) {
            Text(title).frame(width: SearchLayout.chipWidth - 24)
        }
        .onHover(perform: onHover)
        .help(scope.accessibilityLabel)
        .accessibilityLabel(scope.accessibilityLabel)
    }
}

/// The folder list under the scope chip: All and None, then a row per folder with a checkbox, its name, its parent path
/// dimmed and its file count when the engine sends one. Plain layout on the glass, separated by hairlines; a row is not a
/// button, so it is a tap target. Keyboard: `model.folderCursor` marks the row that Return or Space toggles.
struct FolderPopoverView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var scope: FolderScope
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ThemeButton("All", role: .secondary, size: .compact) { scope.setAll(included: true) }
                    .disabled(scope.allIncluded)
                    .accessibilityLabel("Search all folders")
                ThemeButton("None", role: .secondary, size: .compact) { scope.setAll(included: false) }
                    .disabled(scope.included.isEmpty)
                    .accessibilityLabel("Search no folders")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if scope.registered.isEmpty {
                Text("No folders yet. Add one from the menu bar.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(12)
            }
            ForEach(Array(scope.registered.enumerated()), id: \.element) { index, path in
                folderRow(path, cursor: model.folderFocused && model.folderCursor == index + 2)
            }
            Hairline().padding(.top, 8)
            Text("Only changes what is searched. Nothing is deleted.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(12)
        }
        .frame(width: 320, alignment: .leading)
        .glassSurface(radius: 16)
        .onHover(perform: onHover)
    }

    private func folderRow(_ path: String, cursor: Bool) -> some View {
        let url = URL(fileURLWithPath: path)
        let included = scope.isIncluded(path)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: included ? "checkmark.square.fill" : "square")
                .foregroundStyle(included ? Theme.accent : Theme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let files = scope.fileCount(path) {
                Text("\(files) files")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(cursor ? Theme.selected : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { scope.toggle(path) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(url.lastPathComponent), \(included ? "searched" : "left out")")
    }
}

/// A panel that never becomes key: the search field keeps the keyboard, and clicks still reach the list.
final class FolderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// The folder list window. Made once, then shown and hidden. It is a child window of the search panel, so it moves
/// with the panel and stays above it.
final class FolderPopoverController {
    /// Instances made in this process. The headless test checks that hover jitter makes none.
    #if DEBUG
    private(set) static var instancesMade = 0
    #endif

    static let width: CGFloat = 320
    let panel: NSPanel
    private let hosting: NSHostingView<FolderPopoverView>

    init(model: SearchModel, onHover: @escaping (Bool) -> Void) {
        #if DEBUG
        Self.instancesMade += 1
        #endif
        hosting = NSHostingView(rootView: FolderPopoverView(model: model, scope: model.scope, onHover: onHover))
        panel = FolderPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
    }

    /// Set when a hide is running; a show during it cancels the hide's completion.
    private var closing = false
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Shows the list right-aligned under `anchor` (the scope chip), 6 px below it. Animated: a fade and a 6 px slide
    /// in over 140 ms, ease-out. With Reduce Motion, or when `animated` is false, it appears at once.
    func show(below anchor: NSRect, of parent: NSWindow, animated: Bool = true) {
        closing = false
        let height = max(hosting.fittingSize.height, 80)
        let final = NSRect(x: anchor.maxX - Self.width, y: anchor.minY - 6 - height, width: Self.width, height: height)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        guard animated, !Self.reduceMotion else {
            panel.alphaValue = 1
            panel.setFrame(final, display: true)
            panel.orderFront(nil)
            return
        }
        panel.setFrame(final.offsetBy(dx: 0, dy: 6), display: true)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Closes the list: a fade over 100 ms, then it is detached and ordered out. Reduce Motion, or `animated: false`:
    /// at once.
    func hide(animated: Bool = true) {
        closing = true
        let finish = { [weak self] in
            guard let self, self.closing else { return }
            if let parent = self.panel.parent { parent.removeChildWindow(self.panel) }
            self.panel.orderOut(nil)
        }
        guard animated, !Self.reduceMotion, panel.isVisible else {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: finish)
    }
}
