import AppKit

/// The one way a window's height changes in the app: the welcome page as its content grows (Settings never resizes). The top edge is fixed: the
/// frame origin is bottom-left, so the origin moves with the height and the top stays where it was. The height eases in
/// and out over one animation (smoothstep: monotonic, no overshoot). Reduce Motion and tests change it at once.
enum WindowMotion {
    static let duration: TimeInterval = 0.2

    /// A frame of `height` whose top edge is the top edge of `frame`.
    static func topAnchored(_ frame: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// The frame `progress` (0...1) of the way from `from` to `to`, top edge fixed, smoothstep easing.
    static func frame(from: NSRect, to: NSRect, progress: Double) -> NSRect {
        let t = min(max(progress, 0), 1)
        let e = t * t * (3 - 2 * t)
        let height = from.height + (to.height - from.height) * CGFloat(e)
        return topAnchored(from, height: height)
    }

    /// The frames of one change, sampled over `duration` seconds (the animation itself is `duration` long above): with
    /// Reduce Motion the change is one frame, the target. Tests sample it to check every step.
    static func sequence(from: NSRect, to: NSRect, over total: TimeInterval, samples: Int, reduceMotion: Bool) -> [NSRect] {
        if reduceMotion || samples < 2 { return [to] }
        return (0..<samples).map { i in
            let time = total * Double(i) / Double(samples - 1)
            return frame(from: from, to: to, progress: time / duration)
        }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Moves the window to `target` with one animation. The target keeps the window's top edge.
    static func animate(_ window: NSWindow, to target: NSRect, animated: Bool) {
        guard target != window.frame else { return }
        guard animated && !reduceMotion else {
            window.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        }
    }
}
