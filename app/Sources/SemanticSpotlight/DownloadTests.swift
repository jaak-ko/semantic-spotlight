#if DEBUG
import AppKit
import SwiftUI

/// Test only (run by the theme test): the model download. (1) The eased bar over a bursty stream of 100 ms reports:
/// monotonic, never past its target, and no frame moves it by more than 2 points. (2) A cancel from downloading and from
/// retrying: the child is killed (SIGTERM, then SIGKILL after the grace period when it ignores SIGTERM), no zombie is left,
/// the state is "cancelled" (not an error), no retry follows, and the caption shows the bytes on disk. (3) Resume continues
/// from the cancelled value, and the button exists in the welcome block and in Settings.
enum DownloadTests {
    /// The folder the wrapper lives in (removed at the end of the run).
    static var wrapperDirectory: String { NSTemporaryDirectory() + "ss-fetch-test-\(ProcessInfo.processInfo.processIdentifier)" }

    /// The fake fetch script, behind a shell wrapper with the same name the model runs.
    static func fakeBinary() -> String {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/fake_fetch.py").path
        let dir = wrapperDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let wrapper = dir + "/semsearch"
        try? "#!/bin/sh\nexec /usr/bin/env python3 \"\(script)\" \"$@\"\n".write(toFile: wrapper, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        return wrapper
    }

    /// Spins the main run loop until `condition` holds or the time runs out.
    /// Waits until `condition` holds or the time runs out. Suspends (not a nested run loop), so the main queue drains: the
    /// model's events reach it while the test waits.
    @MainActor static func wait(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    /// True once the process is gone and reaped: kill(pid, 0) fails with "no such process" (a zombie would still answer).
    static func reaped(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    @MainActor static func run() async -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("download test: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        failures += easeTest(check: check)
        OnboardingModel.testBinary = fakeBinary()
        check("the fake fetch wrapper exists", FileManager.default.isExecutableFile(atPath: OnboardingModel.testBinary ?? ""),
              OnboardingModel.testBinary ?? "nil")

        // Cancel from downloading: SIGTERM ends the child; the model shows the cancelled state with the bytes so far.
        setenv("FAKE_FETCH_SCENARIO", "slow", 1)
        setenv("FAKE_FETCH_START", "0", 1)
        let model = OnboardingModel()
        model.fetchModel()
        check("downloading: the child runs", await wait(5) { model.childProcessID != nil && model.downloadedBytes.done > 20_000_000 },
              "\(model.download) \(model.downloadedBytes) pid \(model.childProcessID ?? -1)")
        let child = model.childProcessID ?? 0
        model.cancelDownload()
        check("cancel from downloading ends in the cancelled state",
              await wait(5) { if case .cancelled = model.download { return true } else { return false } },
              "\(model.download)")
        let cancelledAt = model.downloadedBytes.done
        if case .cancelled(let done, let total) = model.download {
            check("cancelled: the caption shows the bytes on disk", done == cancelledAt && total == 470_000_000 && done > 20_000_000,
                  pausedCaption(done: done, total: total))
            check("cancelled: the caption reads \"… MB downloaded\"", pausedCaption(done: done, total: total).hasSuffix("MB downloaded"))
        }
        check("cancelled: the child is gone and reaped (no zombie)", await wait(3) { reaped(child) }, "pid \(child)")
        _ = await wait(0.6) { false }   // no retry or error follows a cancel
        if case .cancelled = model.download {} else { check("cancelled: nothing follows (no retry, no error)", false, "\(model.download)") }
        check("cancelled: it is not an error", !{ if case .failed = model.download { return true } else { return false } }())

        // Resume: the same button runs the helper again, from the bytes on disk.
        setenv("FAKE_FETCH_START", String(cancelledAt), 1)
        model.fetchModel()
        check("resume: the download runs again", await wait(3) { model.download == .running })
        check("resume: the bar starts where the download stopped (no jump back)", model.ease.shown >= Double(cancelledAt) / 470_000_000 - 0.001,
              String(format: "%.3f", model.ease.shown))
        check("resume: it continues from the bytes on disk", await wait(4) { model.downloadedBytes.done > cancelledAt },
              "\(model.downloadedBytes.done) vs \(cancelledAt)")
        let resumedChild = model.childProcessID ?? 0
        model.cancelDownload()
        _ = await wait(4) { if case .cancelled = model.download { return true } else { return false } }
        check("resume: a second cancel works too", { if case .cancelled = model.download { return true } else { return false } }())
        _ = await wait(3) { reaped(resumedChild) }

        // Cancel from retrying: the same path, from the retry state.
        setenv("FAKE_FETCH_SCENARIO", "slow-retry", 1)
        setenv("FAKE_FETCH_START", "0", 1)
        let retrying = OnboardingModel()
        retrying.fetchModel()
        check("retrying: the engine reports a retry", await wait(5) { if case .retrying = retrying.download { return true } else { return false } })
        let retryChild = retrying.childProcessID ?? 0
        retrying.cancelDownload()
        check("cancel from retrying ends in the cancelled state",
              await wait(5) { if case .cancelled = retrying.download { return true } else { return false } }, "\(retrying.download)")
        check("retrying: the child is gone and reaped", await wait(3) { reaped(retryChild) })

        // A child that ignores SIGTERM is killed (SIGKILL) after the grace period: still a cancel, not an error.
        setenv("FAKE_FETCH_SCENARIO", "stubborn", 1)
        let stubborn = OnboardingModel()
        stubborn.fetchModel()
        check("stubborn: the child runs", await wait(5) { stubborn.childProcessID != nil && stubborn.downloadedBytes.done > 0 })
        let stubbornChild = stubborn.childProcessID ?? 0
        let asked = Date()
        stubborn.cancelDownload()
        let ended = await wait(5) { if case .cancelled = stubborn.download { return true } else { return false } }
        check("stubborn: killed after the grace period, ends cancelled", ended && Date().timeIntervalSince(asked) >= OnboardingModel.cancelGrace - 0.2,
              String(format: "after %.1f s", Date().timeIntervalSince(asked)))
        check("stubborn: the child is gone and reaped", await wait(3) { reaped(stubbornChild) })

        // The button exists in both places, in the downloading state.
        let welcome = OnboardingModel()
        welcome.download = .running
        welcome.downloadedBytes = (212_000_000, 470_000_000)
        welcome.ease.seed(done: 212_000_000, total: 470_000_000)
        let welcomeFrames = ButtonRowLayoutTests.layout(LanguageModelBlock(model: welcome).frame(width: 380), dark: false)
        check("welcome: Cancel is shown while downloading", welcomeFrames["download.cancel"] != nil)
        let settings = ButtonRowLayoutTests.layout(LanguageModelRow(model: welcome).frame(width: 432), dark: false)
        check("settings: Cancel is shown while downloading", settings["download.cancel"] != nil)
        // An installed model being checked (model_verifying): a neutral line, no Download button, the folder gate closed.
        func status(verifying: Bool) -> EngineStatus {
            EngineStatus(["files": 0, "chunks": 0, "folders": [], "indexing": false, "model": "m", "model_ready": false,
                          "model_verifying": verifying, "folder_stats": []])
        }
        let checking = OnboardingModel()
        checking.apply(status(verifying: true), rows: [])
        check("checking: the engine reports the model is being verified", checking.verifying)
        check("checking: the stage is not Download (nothing to offer)", checking.stage != .download)
        check("checking: the folder gate stays closed", !checking.canChooseFolder)
        let shownChecking = ButtonRowLayoutTests.layout(LanguageModelBlock(model: checking).frame(width: 380), dark: false)
        check("checking: the welcome shows the neutral line, no Download button",
              shownChecking["model.checking"] != nil && shownChecking["model.primary"] == nil)
        let rowChecking = ButtonRowLayoutTests.layout(LanguageModelRow(model: checking).frame(width: 432), dark: false)
        check("checking: Settings shows the neutral line, no Download button",
              rowChecking["model.checking"] != nil && rowChecking["model.primary"] == nil)
        let idle = OnboardingModel()
        idle.apply(status(verifying: false), rows: [])
        check("not checking: the Download button is shown and the stage is Download",
              idle.stage == .download && !idle.verifying
              && ButtonRowLayoutTests.layout(LanguageModelBlock(model: idle).frame(width: 380), dark: false)["model.primary"] != nil)
        OnboardingModel.testBinary = nil
        for name in ["FAKE_FETCH_SCENARIO", "FAKE_FETCH_START"] { unsetenv(name) }
        try? FileManager.default.removeItem(atPath: wrapperDirectory)   // the wrapper's folder
        return failures
    }

    /// The ease over a bursty stream: 100 ms reports with bursts of up to 60 MB, a frame every 1/60 s for six seconds.
    /// Monotonic, never past the target, no frame moves the bar by more than two points. Then Reduce Motion: 4 Hz steps.
    @MainActor static func easeTest(check: (String, Bool, String) -> Void) -> Int {
        func ok(_ name: String, _ condition: Bool) { check(name, condition, "") }
        var clockTime: TimeInterval = 1000
        let ease = DownloadEase()
        ease.clock = { clockTime }
        let bursts = [0, 0, 40_000_000, 3_000_000, 0, 0, 0, 25_000_000, 0, 0, 0, 0, 8_000_000, 0, 0, 60_000_000]
        let total = 470_000_000
        var done = 0
        ease.seed(done: 0, total: total)
        var shown: [Double] = [0]
        var targets: [Double] = []
        var nextEvent = clockTime
        var burst = 0
        let frames = 6 * 60
        for _ in 0..<frames {
            clockTime += 1.0 / 60.0
            if clockTime >= nextEvent {
                done = min(total, done + bursts[burst % bursts.count])
                burst += 1
                ease.report(done: done, total: total, speed: 9_000_000)
                nextEvent += 0.1
            }
            ease.step(now: clockTime)
            shown.append(Double(ease.shown))
            targets.append(ease.target(at: clockTime))
        }
        let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        let monotonic = steps.allSatisfy { $0 >= -1e-12 }
        let maxStep = steps.max() ?? 0
        let neverPast = zip(shown.dropFirst(), targets).allSatisfy { $0 <= $1 + 1e-9 }
        ok("ease: the displayed bar never moves backwards", monotonic)
        check("ease: no frame moves the bar by more than 2 points", maxStep <= 0.02, String(format: "largest step %.4f", maxStep))
        ok("ease: the bar never runs past its target", neverPast)
        let final = targets.last ?? 0
        check("ease: the bar catches up with the stream", abs(Double(ease.shown) - final) < 0.03,
              String(format: "shown %.3f, target %.3f", Double(ease.shown), final))
        // Reduce Motion: no easing; the bar is at its target at each 4 Hz step, and never backwards.
        ease.reduceMotion = true
        var last = Double(ease.shown)
        var reduceMonotonic = true
        var reduceEased = false
        for i in 0..<60 {
            clockTime += 0.25
            if i % 2 == 0 {
                done = min(total, done + 30_000_000)
                ease.report(done: done, total: total, speed: 0)
            }
            ease.step(now: clockTime)
            if abs(Double(ease.shown) - ease.target(at: clockTime)) > 1e-9 { reduceEased = true }
            if Double(ease.shown) < last - 1e-12 { reduceMonotonic = false }
            last = Double(ease.shown)
        }
        ok("reduce motion: the bar is at its target at each step (no easing)", !reduceEased)
        ok("reduce motion: never backwards", reduceMonotonic)
        return 0
    }
}
#endif
