import AppKit
import Foundation
import Testing
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraMenuBarUI

/// G-21 on the status item: the picked mark shows at once, each action plays its ruled motion as frames and ends,
/// Reduce Motion makes every one instant, the Classic ring keeps its sweep, and nothing runs while nothing moves.
@Suite(.serialized) @MainActor struct MenuBarMarkMotionTests {
    @MainActor final class Rig {
        var now = TestData.now
        var busy = false
        var reduceMotion = false
        let model: AppModel
        var presenter: MenuBarMarkPresenter!

        init(mark: MenuBarMarkID = .pixelatedHalf, timers: Bool = false) async throws {
            var settings = Settings.default
            settings.menuBarMark = mark
            model = try await SampleData.model(entries: 0, settings: settings)
            presenter = MenuBarMarkPresenter(model: model, memory: TestData.memory(), clock: { [unowned self] in self.now },
                                             busy: { [unowned self] in self.busy },
                                             reduceMotion: { [unowned self] in self.reduceMotion }, schedulesTimers: timers)
        }

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            presenter.refresh()
        }

        /// Plays the running motion to its end, frame by frame, and returns how many frames it drew.
        func playOut() -> Int {
            var frames = 0
            while presenter.motion != nil, frames < 200 {
                now = now.addingTimeInterval(1 / MarkTimeline.fps)
                presenter.tickMotion()
                frames += 1
            }
            return frames
        }
    }

    @Test func theMotionForEachChangeIsTheRuledOne() {
        let m = MenuBarMarkPresenter.self
        #expect(m.motion(for: .twoTone, from: .protected, to: .caught, clipboard: false) == .caught)
        #expect(m.motion(for: .twoTone, from: .checking, to: .caught, clipboard: true) == .clipboardCleaned)
        #expect(m.motion(for: .twoTone, from: .protected, to: .paused, clipboard: false) == .pauseCrossFade)
        #expect(m.motion(for: .twoTone, from: .paused, to: .protected, clipboard: false) == .pauseCrossFade)
        #expect(m.motion(for: .twoTone, from: .protected, to: .needsAttention, clipboard: false) == .needsYouPop)
        #expect(m.motion(for: .twoTone, from: .protected, to: .waiting, clipboard: false) == .updateFade)
        #expect(m.motion(for: .twoTone, from: .caught, to: .protected, clipboard: false) == .dotFadeOut)
        #expect(m.motion(for: .twoTone, from: .protected, to: .partlyProtected, clipboard: false) == nil, "instant")
        #expect(m.motion(for: .twoTone, from: .protected, to: .checking, clipboard: false) == nil, "checking loops instead")
        // The Classic ring keeps G-15: only its dots fade.
        #expect(m.motion(for: .classic, from: .protected, to: .caught, clipboard: false) == .updateFade)
        #expect(m.motion(for: .classic, from: .caught, to: .protected, clipboard: false) == .dotFadeOut)
        #expect(m.motion(for: .classic, from: .protected, to: .paused, clipboard: false) == nil)
    }

    @Test func aCatchSnapsShutThenShowsTheDotWithinSixTenths() async throws {
        let rig = try await Rig()
        rig.model.recordCatch(fromClipboard: false, at: rig.now)
        rig.presenter.refresh()
        #expect(rig.presenter.state == .caught)
        #expect(rig.presenter.motion?.kind == .caught)
        let first = rig.presenter.image
        let frames = rig.playOut()
        #expect(frames >= 2 && frames <= 37, "\(frames) frames")
        #expect(rig.presenter.motion == nil, "the motion ended")
        #expect(rig.presenter.image !== first)
        #expect(rig.presenter.state == .caught, "the green dot stays for its 4 s")
    }

    @Test func aClipboardCatchWipes() async throws {
        let rig = try await Rig(mark: .twoTone)
        rig.model.recordCatch(fromClipboard: true, at: rig.now)
        rig.presenter.refresh()
        #expect(rig.presenter.motion?.kind == .clipboardCleaned)
        _ = rig.playOut()
        #expect(rig.presenter.motion == nil)
    }

    @Test func copyCleanPulsesAndUndoLiftsTheCoverUntilCoveredAgain() async throws {
        let rig = try await Rig(mark: .halfBar)
        rig.model.recordCopiedClean()
        rig.presenter.refresh()
        #expect(rig.presenter.motion?.kind == .copyClean)
        _ = rig.playOut()

        rig.model.recordOriginalShowing(UUID())
        rig.presenter.refresh()
        #expect(rig.presenter.motion?.kind == .coverLifts)
        _ = rig.playOut()
        #expect(rig.presenter.lifted)
        #expect(rig.presenter.current().0.pose == .lifted, "the cover stays lifted while the original shows")
        let lifted = rig.presenter.image

        rig.model.recordOriginalShowing(nil)
        rig.presenter.refresh()
        #expect(rig.presenter.motion?.kind == .coverReturns)
        _ = rig.playOut()
        #expect(rig.presenter.current().0.pose == MarkPose())
        #expect(rig.presenter.image !== lifted)
    }

    @Test func reduceMotionMakesEveryActionItsEndAtOnce() async throws {
        let rig = try await Rig()
        rig.reduceMotion = true
        rig.model.recordCatch(fromClipboard: false, at: rig.now)
        rig.presenter.refresh()
        #expect(rig.presenter.state == .caught && rig.presenter.motion == nil)
        rig.model.recordCopiedClean()
        rig.presenter.refresh()
        #expect(rig.presenter.motion == nil)
        rig.model.recordOriginalShowing(UUID())
        rig.presenter.refresh()
        #expect(rig.presenter.motion == nil)
        #expect(rig.presenter.current().0.pose == .lifted, "the end state still shows")
    }

    @Test func checkingLoopsTheScanLineAndTheClassicRingKeepsItsSweep() async throws {
        let rig = try await Rig(mark: .scanlines)
        rig.busy = true
        rig.advance(0)
        rig.advance(0.31)
        #expect(rig.presenter.state == .checking)
        let first = rig.presenter.image
        for _ in 0..<MarkTimeline.scanFrames { rig.presenter.advanceSweep() }
        #expect(rig.presenter.sweepIndex == 0, "a whole loop")
        #expect(rig.presenter.image === first, "the loop's frames are drawn once and reused")
        #expect(rig.presenter.current().0.pose.scanY != nil)

        rig.reduceMotion = true
        rig.advance(0)
        #expect(rig.presenter.current().0.pose.scanY == nil, "Reduce Motion: the line stands still in the middle")

        let classic = try await Rig(mark: .classic)
        classic.busy = true
        classic.advance(0)
        classic.advance(0.31)
        classic.presenter.advanceSweep()
        #expect(classic.presenter.current().0.sweep > 0, "the Classic ring sweeps")
        for _ in 1..<MarkTiming.sweepFrames { classic.presenter.advanceSweep() }
        #expect(classic.presenter.sweepIndex == 0)
    }

    @Test func pickingAMarkOrStyleShowsItAtOnce() async throws {
        let rig = try await Rig(mark: .classic)
        let classic = rig.presenter.image
        #expect(classic.isTemplate, "the Classic ring at rest is the template, as before")
        rig.model.updateSettings { $0.menuBarMark = .shutter }
        rig.presenter.refresh()
        #expect(rig.presenter.image !== classic)
        #expect(!rig.presenter.image.isTemplate, "Warm by default: a colour image")
        #expect(rig.presenter.motion == nil, "a new pick appears in its resting look")
        rig.model.updateSettings { $0.menuBarMarkStyle = .oneColor }
        rig.presenter.refresh()
        #expect(rig.presenter.image.isTemplate)
        #expect(rig.presenter.accessibilityLabel == MarkCopy.accessibilityLabel(.protected), "the words are unchanged")
    }

    @Test func theBarsAppearanceRedrawsTheInk() async throws {
        let rig = try await Rig(mark: .twoTone)
        rig.presenter.barAppearance = .light
        let light = rig.presenter.image
        rig.presenter.barAppearance = .dark
        #expect(rig.presenter.image !== light)
        let dark = rig.presenter.image
        rig.presenter.barAppearance = MarkAppearance(isDark: true, isEmphasized: true)
        #expect(rig.presenter.image !== dark, "highlighted on an emphasized background draws the plain part white")
    }

    @Test func nothingRunsWhileNothingMoves() async throws {
        let rig = try await Rig(mark: .orbit, timers: true)
        #expect(!rig.presenter.hasRunningTimers, "at rest: no timer")
        rig.busy = true
        rig.now = Date()
        rig.presenter.refresh()
        rig.now = Date().addingTimeInterval(0.31)
        rig.presenter.refresh()
        #expect(rig.presenter.state == .checking)
        #expect(rig.presenter.hasRunningTimers, "the scan line loops while checking")
        rig.busy = false
        rig.now = rig.now.addingTimeInterval(1)
        rig.presenter.refresh()
        #expect(rig.presenter.state == .protected)
        #expect(!rig.presenter.hasRunningTimers, "the loop stops with the check")
    }
}
