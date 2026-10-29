import AppKit
import Foundation
import Testing
import ObscuraUIKit
@testable import ObscuraMenuBarUI

/// The mark as shown over time: the gated checking state (S-9), the reused sweep frames and Reduce Motion (S-10).
@Suite(.serialized) @MainActor struct MenuBarMarkTests {
    @MainActor final class Rig {
        var now = TestData.now
        var busy = false
        var reduceMotion = false
        let model: AppModel
        var presenter: MenuBarMarkPresenter!

        init() async throws {
            model = try await SampleData.model(entries: 0)
            presenter = MenuBarMarkPresenter(model: model, memory: TestData.memory(), clock: { [unowned self] in self.now },
                                             busy: { [unowned self] in self.busy },
                                             reduceMotion: { [unowned self] in self.reduceMotion }, schedulesTimers: false)
        }

        func advance(_ seconds: TimeInterval, busy: Bool? = nil) {
            now = now.addingTimeInterval(seconds)
            if let busy { self.busy = busy }
            presenter.refresh()
        }
    }

    @Test func aWarmScanDoesNotBlinkTheMark() async throws {
        let rig = try await Rig()
        var changes = 0
        rig.presenter.onChange = { _ in changes += 1 }
        rig.advance(0, busy: true)
        #expect(rig.presenter.state == .protected)
        rig.advance(0.1, busy: false)
        #expect(rig.presenter.state == .protected)
        #expect(changes == 0, "the status item's image never changed")
        #expect(rig.model.markState == .protected)
    }

    @Test func aSlowCheckShowsThenHoldsItsMinimum() async throws {
        let rig = try await Rig()
        rig.advance(0, busy: true)
        rig.advance(0.31)  // past the reveal (wall-clock seconds are not exact in binary)
        #expect(rig.presenter.state == .checking)
        #expect(rig.presenter.showsChecking)
        #expect(rig.presenter.accessibilityLabel == MarkCopy.accessibilityLabel(.checking))
        rig.advance(0.1, busy: false)
        #expect(rig.presenter.state == .checking, "half a turn at least")
        rig.advance(MarkTiming.checkingMinimum)
        #expect(rig.presenter.state == .protected)
    }

    @Test func theSweepReusesItsFramesAndStandsStillUnderReduceMotion() async throws {
        let rig = try await Rig()
        rig.advance(0, busy: true)
        rig.advance(0.31)  // past the reveal (wall-clock seconds are not exact in binary)
        let first = rig.presenter.image
        rig.presenter.advanceSweep()
        #expect(rig.presenter.image !== first, "the arc moved one frame")
        for _ in 1..<MarkTiming.sweepFrames { rig.presenter.advanceSweep() }
        #expect(rig.presenter.sweepIndex == 0, "a whole turn")
        #expect(rig.presenter.image === first, "the turn's frames are drawn once and reused")

        rig.reduceMotion = true
        rig.presenter.advanceSweep()
        rig.advance(0)
        #expect(rig.presenter.sweepIndex == 0, "Reduce Motion: the arc stands still")
        #expect(rig.presenter.state == .checking, "the state itself still shows")
    }

    @Test func theSharedPresenterIsOnePerModel() async throws {
        let model = try await SampleData.model(entries: 0)
        #expect(MenuBarMarkPresenter.shared(for: model) === MenuBarMarkPresenter.shared(for: model))
    }
}
