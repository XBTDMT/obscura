import Foundation
import Testing
import ObscuraPrefs
@testable import ObscuraCapture
@testable import ObscuraEngine
@testable import ObscuraThumbnailUI

/// The state machine: which card shows for a start or a report, the checking reveal, fold, countdown, hover and bursts.
@Suite struct ThumbnailStackTests {
    static let shot = URL(fileURLWithPath: "/home/example/Desktop/Screenshot 2026-10-26 at 9.41.12 AM.png")
    static func key(_ n: Int = 1) -> CaptureKey { .path("/home/example/Desktop/Screenshot \(n).png") }
    static let id = UUID()

    func started(_ keys: [Int] = [1], at t: TimeInterval = 0) -> ThumbnailStack {
        var s = ThumbnailStack()
        for k in keys { s.start(key: Self.key(k), displayName: "Screenshot \(k).png", fileURL: Self.shot, screenPoint: .zero, at: t) }
        return s
    }

    @Test func onlyNewScreenshotsWithAFileAreShownWhileOn() {
        #expect(ThumbnailStack.accepts(origin: .screenshotFolder, hasFile: true, enabled: true))
        #expect(!ThumbnailStack.accepts(origin: .screenshotFolder, hasFile: true, enabled: false))
        #expect(!ThumbnailStack.accepts(origin: .screenshotFolder, hasFile: false, enabled: true))
        #expect(!ThumbnailStack.accepts(origin: .downloads, hasFile: true, enabled: true))
        #expect(!ThumbnailStack.accepts(origin: .watched(URL(fileURLWithPath: "/home/example/Shots")), hasFile: true, enabled: true))
        #expect(!ThumbnailStack.accepts(origin: .imported, hasFile: true, enabled: true))
        #expect(!ThumbnailStack.accepts(origin: nil, hasFile: false, enabled: true), "clipboard")
    }

    @Test func aFastCheckSlidesInWithItsResultAndNoCheckingCard() {
        var s = started()
        #expect(s.tick(at: 0.1) == .none)
        #expect(!s.isVisible)
        #expect(s.report(key: Self.key(), result: .clean, duration: 5, at: 0.12) == .appear)
        #expect(s.front?.phase == .clean)
        #expect(s.deadline == 5.12)
        #expect(CapsuleKind(s.front!) == .checked)
        #expect(!s.isTracking(Self.key()))
    }

    @Test func aSlowCheckShowsCheckingThenTheResultInPlace() {
        var s = started()
        #expect(s.nextWakeup() == ThumbnailStack.checkingDelay)
        #expect(s.tick(at: 0.3) == .appear)
        #expect(s.front?.phase == .checking)
        #expect(s.deadline == nil, "no countdown while checking")
        #expect(s.nextWakeup() == ThumbnailStack.defaultCheckingCeiling, "only the ceiling is left to wake for")
        #expect(s.report(key: Self.key(), result: .redacted(entryID: Self.id, findings: 2), duration: 5, at: 1.0) == .update)
        #expect(s.front?.phase == .covered(entryID: Self.id, findings: 2))
        #expect(s.edges == 0, "the result replaces its own checking card")
        #expect(s.deadline == 6.0, "the countdown starts when the result shows")
    }

    @Test func checkedFoldsAfterOneAndAHalfSecondsButCoveredNeverDoes() {
        var s = started()
        _ = s.report(key: Self.key(), result: .clean, duration: 5, at: 0)
        #expect(s.nextWakeup() == 1.5)
        #expect(s.tick(at: 1.49) == .none)
        #expect(s.tick(at: 1.5) == .update)
        #expect(CapsuleKind(s.front!) == .folded)

        var c = started()
        _ = c.report(key: Self.key(), result: .redacted(entryID: Self.id, findings: 2), duration: 5, at: 0)
        #expect(c.tick(at: 2) == .none)
        #expect(CapsuleKind(c.front!) == .covered(2))
    }

    @Test func itLeavesAfterTheDurationFromSettings() {
        var s = started()
        _ = s.report(key: Self.key(), result: .redacted(entryID: Self.id, findings: 1), duration: 8, at: 0)
        #expect(s.tick(at: 7.9) == .none)
        #expect(s.tick(at: 8) == .hide)
        #expect(!s.isVisible)
    }

    @Test func hoverPausesTheCountdownAndLeavingResumesIt() {
        var s = started()
        _ = s.report(key: Self.key(), result: .redacted(entryID: Self.id, findings: 1), duration: 5, at: 0)
        s.setHold(.hover, true, at: 2)
        #expect(s.deadline == nil)
        #expect(s.remaining == 3)
        #expect(s.tick(at: 60) == .none, "stays while the pointer is over it")
        s.setHold(.hover, false, at: 60)
        #expect(s.deadline == 63)
        #expect(s.tick(at: 63) == .hide)
    }

    @Test func leavingNearTheEndStillLeavesAMoment() {
        var s = started()
        _ = s.report(key: Self.key(), result: .clean, duration: 5, at: 0)
        s.setHold(.hover, true, at: 4.9)
        s.setHold(.hover, false, at: 9)
        #expect(s.deadline == 9 + ThumbnailStack.minimumAfterHold)
    }

    @Test func holdsStackAndOnlyTheLastReleaseResumes() {
        var s = started()
        _ = s.report(key: Self.key(), result: .clean, duration: 5, at: 0)
        s.setHold(.hover, true, at: 1)
        s.setHold(.menu, true, at: 1)
        s.setHold(.hover, false, at: 2)
        #expect(s.deadline == nil, "the menu is still open")
        s.setHold(.menu, false, at: 3)
        #expect(s.deadline == 7)
    }

    @Test func aResultWhileHoveringWaitsTheFullDurationAfterRelease() {
        var s = started([1, 2])
        _ = s.report(key: Self.key(1), result: .clean, duration: 5, at: 0)
        s.setHold(.hover, true, at: 1)
        _ = s.report(key: Self.key(2), result: .clean, duration: 5, at: 2)
        #expect(s.remaining == 5)
        s.setHold(.hover, false, at: 10)
        #expect(s.deadline == 15)
    }

    @Test func aBurstShowsTheNewestWithAtMostTwoEdges() {
        var s = started([1, 2, 3, 4])
        #expect(s.report(key: Self.key(1), result: .clean, duration: 5, at: 0) == .appear)
        #expect(s.edges == 0)
        #expect(s.report(key: Self.key(2), result: .redacted(entryID: Self.id, findings: 2), duration: 5, at: 1) == .update)
        #expect(s.edges == 1)
        _ = s.report(key: Self.key(3), result: .clean, duration: 5, at: 2)
        #expect(s.edges == 2)
        _ = s.report(key: Self.key(4), result: .clean, duration: 5, at: 3)
        #expect(s.edges == 2)
        #expect(s.cards.count == 3)
        #expect(s.front?.key == Self.key(4))
        #expect(s.deadline == 8, "each new shot restarts the countdown")
        #expect(s.tick(at: 8) == .hide)
        #expect(s.edges == 0, "the edges leave with the thumbnail")
    }

    @Test func aDroppedScanRemovesItsCheckingCard() {
        var s = started()
        #expect(s.tick(at: 0.3) == .appear)
        #expect(s.report(key: Self.key(), result: .dropped, duration: 5, at: 2) == .hide)
        #expect(!s.isTracking(Self.key()))
    }

    @Test func aDroppedScanBeforeTheRevealShowsNothing() {
        var s = started()
        #expect(s.report(key: Self.key(), result: .dropped, duration: 5, at: 0.1) == .none)
        #expect(s.tick(at: 1) == .none)
        #expect(!s.isVisible)
    }

    @Test func aDroppedCheckingCardUncoversTheShotBehindIt() {
        var s = started([1])
        _ = s.report(key: Self.key(1), result: .clean, duration: 5, at: 0)
        s.start(key: Self.key(2), displayName: "Screenshot 2.png", fileURL: Self.shot, screenPoint: .zero, at: 1)
        #expect(s.tick(at: 1.3) == .update)
        #expect(s.front?.phase == .checking)
        #expect(s.edges == 1)
        #expect(s.report(key: Self.key(2), result: .dropped, duration: 5, at: 2) == .update)
        #expect(s.front?.key == Self.key(1))
        #expect(s.edges == 0)
    }

    @Test func aCancelledOlderScanOfTheSameFileKeepsTheNewerOnesCard() {
        var s = started()
        s.start(key: Self.key(), displayName: "Screenshot 1.png", fileURL: Self.shot, screenPoint: .zero, at: 0.05)
        #expect(s.tick(at: 0.35) == .appear)
        #expect(s.report(key: Self.key(), result: .dropped, duration: 5, at: 0.4) == .none, "the older scan was cancelled")
        #expect(s.front?.phase == .checking)
        #expect(s.report(key: Self.key(), result: .clean, duration: 5, at: 0.6) == .update)
        #expect(s.front?.phase == .clean)
    }

    @Test func aReportWithoutItsStartShowsNothing() {
        var s = ThumbnailStack()
        #expect(s.report(key: Self.key(), result: .clean, duration: 5, at: 0) == .none)
        #expect(!s.isVisible)
    }

    @Test func aCheckingCardInFrontNeverTimesOut() {
        var s = started([1])
        _ = s.report(key: Self.key(1), result: .clean, duration: 5, at: 0)
        s.start(key: Self.key(2), displayName: "Screenshot 2.png", fileURL: Self.shot, screenPoint: .zero, at: 4.5)
        _ = s.tick(at: 4.8)
        #expect(s.tick(at: 6) != .hide)
        #expect(s.isVisible)
        _ = s.report(key: Self.key(2), result: .clean, duration: 5, at: 7)
        #expect(s.deadline == 12)
    }

    @Test func undoAndRedoChangeThePhaseInPlace() {
        var s = started()
        _ = s.report(key: Self.key(), result: .redacted(entryID: Self.id, findings: 2), duration: 5, at: 0)
        #expect(s.setPhase(.original(entryID: Self.id, findings: 2), for: Self.key()) == .update)
        #expect(CapsuleKind(s.front!) == .original(2))
        #expect(HoverAction(s.front!.phase) == .blackOutAgain)
        #expect(s.setPhase(.original(entryID: Self.id, findings: 2), for: Self.key()) == .none)
    }

    @Test func dismissClearsCardsAndHolds() {
        var s = started()
        _ = s.report(key: Self.key(), result: .clean, duration: 5, at: 0)
        s.setHold(.hover, true, at: 1)
        #expect(s.dismiss() == .hide)
        #expect(!s.isVisible)
        #expect(s.holds.isEmpty)
        #expect(s.dismiss() == .none)
    }

    // MARK: Checking ceiling (G-9: defence for a scan whose report never comes)

    @Test func theCeilingIsTheEngineOCRDeadlinePlusTheMargin() {
        var settings = Settings.default
        #expect(ThumbnailStack.defaultCheckingCeiling == PipelineConstants.ocrDeadlineSeconds(settings) + ThumbnailStack.ceilingMargin)
        #expect(ThumbnailStack.defaultCheckingCeiling > Double(PipelineConstants.ocrTimeout.components.seconds),
                "a card never gives up before the engine's own deadline")
        settings.ocrTimeoutSeconds = 45
        #expect(ThumbnailStack.checkingCeiling(ocrDeadline: PipelineConstants.ocrDeadlineSeconds(settings)) == 45 + ThumbnailStack.ceilingMargin)
        settings.ocrTimeoutSeconds = 0
        #expect(ThumbnailStack.checkingCeiling(ocrDeadline: PipelineConstants.ocrDeadlineSeconds(settings)) == 1 + ThumbnailStack.ceilingMargin,
                "the engine never scans under less than 1 s, and neither does the ceiling")
    }

    @Test func aCheckingCardWhoseReportNeverComesLeavesAtTheCeiling() {
        let ceiling = ThumbnailStack.defaultCheckingCeiling
        var s = started()
        #expect(s.tick(at: 0.3) == .appear)
        #expect(s.nextWakeup() == ceiling)
        #expect(s.tick(at: ceiling - 0.01) == .none, "still inside the ceiling")
        #expect(s.front?.phase == .checking)
        #expect(s.tick(at: ceiling) == .hide)
        #expect(!s.isVisible)
        #expect(s.tick(at: ceiling + 1) == .none, "an expired scan never shows a checking card again")
        #expect(s.nextWakeup() == nil)
        #expect(!s.liveKeys.contains(Self.key()), "its image is not held")
    }

    @Test func aReportAfterTheCeilingStillShowsItsResult() {
        let ceiling = ThumbnailStack.defaultCheckingCeiling
        var s = started()
        _ = s.tick(at: 0.3)
        #expect(s.tick(at: ceiling) == .hide)
        #expect(s.report(key: Self.key(), result: .redacted(entryID: Self.id, findings: 1), duration: 5, at: ceiling + 3) == .appear,
                "a slow scan's catch keeps its notice")
        #expect(s.front?.phase == .covered(entryID: Self.id, findings: 1))
        #expect(!s.isTracking(Self.key()))
    }

    @Test func anExpiredCheckingCardUncoversTheShotBehindIt() {
        var s = started([1])
        _ = s.report(key: Self.key(1), result: .clean, duration: 5, at: 0)
        s.start(key: Self.key(2), displayName: "Screenshot 2.png", fileURL: Self.shot, screenPoint: .zero, at: 1, ceiling: 2)
        #expect(s.tick(at: 1.3) == .update)
        #expect(s.front?.phase == .checking)
        #expect(s.tick(at: 3) == .update)
        #expect(s.front?.key == Self.key(1))
        #expect(s.edges == 0)
        #expect(s.deadline == 5, "the shot behind keeps its own countdown")
    }

    @Test func aRepeatedStartRenewsTheCeiling() {
        var s = started()
        _ = s.tick(at: 0.3)
        s.start(key: Self.key(), displayName: "Screenshot 1.png", fileURL: Self.shot, screenPoint: .zero, at: 10)
        #expect(s.tick(at: ThumbnailStack.defaultCheckingCeiling) != .hide, "the newer scan has its own ceiling")
        #expect(s.front?.phase == .checking)
        #expect(s.tick(at: 10 + ThumbnailStack.defaultCheckingCeiling) == .hide)
    }

    @Test func aResultJustAfterTheRevealWaitsUntilTheCheckingCardHasBeenSeen() {
        var s = started()
        #expect(s.tick(at: 0.3) == .appear)
        // The check ends 0.05 s into the slide-in: no "Checking…" flash, the result comes once the card has landed.
        #expect(s.report(key: Self.key(), result: .clean, duration: 5, at: 0.35) == .none)
        #expect(s.front?.phase == .checking)
        #expect(s.isTracking(Self.key()), "still the thumbnail's scan until the result shows")
        #expect(s.nextWakeup() == 0.3 + ThumbnailStack.checkingMinimum)
        #expect(s.tick(at: 0.79) == .none)
        #expect(s.tick(at: 0.8) == .update)
        #expect(s.front?.phase == .clean)
        #expect(s.deadline == 5.8, "the countdown starts when the result shows")
        #expect(!s.isTracking(Self.key()))
    }

    @Test func aHeldDropRemovesTheCheckingCardOnceSeen() {
        var s = started()
        _ = s.tick(at: 0.3)
        #expect(s.report(key: Self.key(), result: .dropped, duration: 5, at: 0.4) == .none)
        #expect(s.tick(at: 0.8) == .hide)
        #expect(!s.isVisible)
    }

    @Test func dismissingACardWithAHeldResultEndsItsScan() {
        var s = started()
        _ = s.tick(at: 0.3)
        _ = s.report(key: Self.key(), result: .clean, duration: 5, at: 0.4)
        #expect(s.dismiss() == .hide)
        #expect(!s.isTracking(Self.key()), "the held report counted")
        #expect(s.tick(at: 2) == .none, "no checking card comes back for it")
        #expect(!s.isVisible)
    }

    @Test func outcomesMapToResults() {
        let id = UUID()
        #expect(ShotResult(.clean(duration: .milliseconds(90))) == .clean)
        #expect(ShotResult(.redacted(entryID: id, findings: 3, duration: .milliseconds(120))) == .redacted(entryID: id, findings: 3))
        #expect(ShotResult(.skipped(.ocrTimeout)) == .dropped)
        #expect(ShotResult(.failed(.writeBack("disk full"))) == .dropped)
    }
}
