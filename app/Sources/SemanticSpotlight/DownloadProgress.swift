import AppKit
import SwiftUI

/// The shown fraction of a model download. The engine reports bytes about every 100 ms, in bursts; the bar must not jump.
/// So the shown value eases toward the target: the last reported bytes, plus what the reported speed predicts since then
/// (at most one second ahead), clamped to the total. It never moves backwards and never passes its target. Only the bar
/// observes this object, so the ticks redraw the bar and nothing else. Reduce Motion: no easing, the target at 4 Hz.
final class DownloadEase: ObservableObject {
    /// The fraction drawn (0...1).
    @Published private(set) var shown: Double = 0
    var clock: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    var reduceMotion = false

    private var done: Double = 0
    private var peak: Double = 0           // the highest target so far (targets never fall)
    private var total: Double = 0
    private var speed: Double = 0          // bytes per second, as the engine reports it (0 when unknown)
    private var reportedAt: TimeInterval = 0
    private var lastStep: TimeInterval = 0
    private var timer: Timer?

    /// The time constant of the ease: a burst is drawn in about a fifth of a second.
    static let timeConstant: Double = 1.0 / 6.0
    /// How far ahead of the last report the speed may place the target.
    static let maxLead: TimeInterval = 1.0
    /// The frame rate of the ease (30 to 60 Hz), and the rate with Reduce Motion.
    static let frameInterval: TimeInterval = 1.0 / 60.0
    static let reduceMotionInterval: TimeInterval = 0.25

    /// Starts from a known position (a new download, or a resumed one): the bar shows it at once, with no ease.
    func seed(done: Int, total: Int) {
        self.done = Double(done)
        self.total = Double(total)
        speed = 0
        reportedAt = clock()
        lastStep = reportedAt
        peak = fraction(of: self.done)
        shown = peak
    }

    /// A progress line from the engine. Never reports fewer bytes than before.
    func report(done: Int, total: Int, speed: Double) {
        guard total > 0 else { return }
        self.done = max(self.done, Double(done))
        self.total = Double(total)
        self.speed = max(0, speed)
        reportedAt = clock()
    }

    /// The target the shown value eases toward at `now`. It never falls: a report that comes in below the speed's
    /// prediction moves the target back to the bytes, but the bar keeps its place until the bytes catch up.
    func target(at now: TimeInterval) -> Double {
        guard total > 0 else { return 0 }
        let lead = speed * min(max(0, now - reportedAt), Self.maxLead)
        peak = max(peak, fraction(of: min(done + lead, total)))
        return peak
    }

    /// One frame: the shown value moves toward the target. Never backwards, never past the target.
    func step(now: TimeInterval) {
        let t = target(at: now)
        if reduceMotion {
            shown = max(shown, t)
        } else {
            let dt = max(0, now - lastStep)
            let k = 1 - exp(-dt / Self.timeConstant)
            shown = max(shown, min(t, shown + (t - shown) * k))
        }
        lastStep = now
    }

    /// Runs the ease on the main run loop while the bar is on screen.
    func attach(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        timer?.invalidate()
        let interval = reduceMotion ? Self.reduceMotionInterval : Self.frameInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.step(now: self.clock())
        }
    }

    func detach() {
        timer?.invalidate()
        timer = nil
    }

    private func fraction(of bytes: Double) -> Double {
        total > 0 ? min(max(bytes / total, 0), 1) : 0
    }
}

/// The download's bar: the eased fraction, drawn at its width with no animation of its own (the ease is the animation).
struct DownloadProgressBar: View {
    @ObservedObject var ease: DownloadEase
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.edge)
                Capsule().fill(Theme.accent)
                    .frame(width: max(height, geo.size.width * ease.shown))
            }
        }
        .frame(height: height)
        .animation(nil, value: ease.shown)
        .onAppear { ease.attach(reduceMotion: reduceMotion) }
        .onDisappear { ease.detach() }
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int((ease.shown * 100).rounded())) percent")
    }
}

/// Cancel while a download runs (welcome and Settings): a quiet text button, the tertiary role.
struct DownloadCancelButton: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ThemeButton("Cancel", role: .tertiary, size: .compact) { model.cancelDownload() }
            .layoutProbe("download.cancel")
    }
}

/// The caption of a paused download: its size so far, or a plain line when the total is not known yet.
func pausedCaption(done: Int, total: Int) -> String {
    total > 0 ? "\(done / 1_000_000) of \(total / 1_000_000) MB downloaded" : "Download paused"
}
