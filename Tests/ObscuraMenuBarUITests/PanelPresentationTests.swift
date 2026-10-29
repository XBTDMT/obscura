// The menu bar panel's open/close rules (G-14, G-15; recon M-1, M-2): which action closes it and when, where focus goes,
// and where the panel sits.
import CoreGraphics
import Foundation
import Testing
@testable import ObscuraMenuBarUI

@Suite struct PanelPresentationTests {
    static let id = UUID()
    static let ownPID: pid_t = 100
    static let slack: pid_t = 200

    /// The eleven window-opening actions of the recon's table, plus Install Update's banner button (the same action).
    static let windowOpening: [PanelAction] = [
        .review(id), .openJournal, .openJournalNotChecked, .openSettings(.protection), .openSettings(.detectors),
        .openSettings(.customRules), .openSetup, .checkForUpdates, .installUpdate,
    ]
    /// The actions that work in place and leave the panel open.
    static let inPlace: [PanelAction] = [
        .undo(id), .blackOutAgain(id), .pause(.oneHour), .pause(.untilResumed), .resume, .dismissUpdate,
        .stopWatching(.downloads), .stopWatching(.screenshotFolder), .checkAgain,
    ]

    @Test func everyWindowOpeningActionClosesThePanelFirst() {
        for action in Self.windowOpening {
            #expect(PanelPresentation.closeTiming(for: action) == .beforePerforming, "\(action)")
            #expect(PanelPresentation.closes(action, at: .willPerform), "\(action)")
            #expect(!PanelPresentation.closes(action, at: .didPerform), "\(action) closes once, before")
        }
    }

    @Test func inPlaceActionsKeepThePanelOpen() {
        for action in Self.inPlace + [.quit] {
            #expect(PanelPresentation.closeTiming(for: action) == .never, "\(action)")
            #expect(!PanelPresentation.closes(action, at: .willPerform))
            #expect(!PanelPresentation.closes(action, at: .didPerform))
        }
    }

    @Test func copyCleanClosesOnceTheCopyIsDone() {
        let copy = PanelAction.copyClean(Self.id)
        #expect(PanelPresentation.closeTiming(for: copy) == .afterPerforming)
        #expect(!PanelPresentation.closes(copy, at: .willPerform))
        #expect(PanelPresentation.closes(copy, at: .didPerform))
    }

    @Test func everyBannerButtonAndMenuRowIsCovered() {
        // Each action the panel can show has a rule; the switch is exhaustive, so this guards the lists above instead.
        let all = Self.windowOpening + Self.inPlace + [.copyClean(Self.id), .quit]
        #expect(Set(all).count == all.count)
    }

    @Test func copyCleanReturnsFocusToTheAppTheUserCameFrom() {
        var p = PanelPresentation()
        let r1 = p.open(frontmostApp: Self.slack, ownPID: Self.ownPID)
        #expect(r1)
        let r2 = p.close(.action(.copyClean(Self.id)))
        #expect(r2 == .activate(Self.slack))
        #expect(!p.isOpen)
    }

    @Test func escapeAndASecondClickReturnFocusToo() {
        for reason: PanelPresentation.CloseReason in [.escape, .statusItemClicked] {
            var p = PanelPresentation()
            _ = p.open(frontmostApp: Self.slack, ownPID: Self.ownPID)
            let r3 = p.close(reason)
            #expect(r3 == .activate(Self.slack), "\(reason)")
        }
    }

    @Test func goingSomewhereElseLeavesFocusAlone() {
        let reasons: [PanelPresentation.CloseReason] = [
            .windowOpening, .clickedOutside, .appResignedActive, .panelResignedKey, .action(.openJournal), .action(.review(Self.id)),
        ]
        for reason in reasons {
            var p = PanelPresentation()
            _ = p.open(frontmostApp: Self.slack, ownPID: Self.ownPID)
            let r4 = p.close(reason)
            #expect(r4 == PanelPresentation.FocusReturn.none, "\(reason)")
        }
    }

    @Test func openedFromObscuraItselfThereIsNoOtherAppToReturnTo() {
        var p = PanelPresentation()
        _ = p.open(frontmostApp: Self.ownPID, ownPID: Self.ownPID)
        #expect(p.previousApp == nil)
        let r5 = p.close(.action(.copyClean(Self.id)))
        #expect(r5 == PanelPresentation.FocusReturn.none)
    }

    @Test func openAndCloseAreIdempotent() {
        var p = PanelPresentation()
        let r6 = p.close(.escape)
        #expect(r6 == nil, "closing a closed panel does nothing")
        let r7 = p.open(frontmostApp: Self.slack, ownPID: Self.ownPID)
        #expect(r7)
        let r8 = p.open(frontmostApp: 300, ownPID: Self.ownPID)
        #expect(!r8, "a second open does nothing")
        #expect(p.previousApp == Self.slack, "and keeps the app the panel was first opened over")
        let r9 = p.close(.windowOpening)
        #expect(r9 != nil)
        let r10 = p.close(.windowOpening)
        #expect(r10 == nil, "the router and the panel's own action may both close it; once counts")
        #expect(p.previousApp == nil)
    }

    // MARK: Placement

    /// A 1440 × 900 screen with a 24 pt menu bar.
    static let visible = CGRect(x: 0, y: 0, width: 1440, height: 876)
    static let size = CGSize(width: 310, height: 420)

    @Test func thePanelHangsUnderTheItemLikeAMenu() {
        let item = CGRect(x: 1000, y: 876, width: 28, height: 24)
        let frame = PanelPresentation.frame(contentSize: Self.size, item: item, visible: Self.visible)
        #expect(frame.minX == 1000)
        #expect(frame.maxY == 876 - PanelPresentation.gapBelowMenuBar)
        #expect(frame.size == Self.size)
    }

    @Test func nearTheRightEdgeItStaysOnScreen() {
        let item = CGRect(x: 1400, y: 876, width: 28, height: 24)
        let frame = PanelPresentation.frame(contentSize: Self.size, item: item, visible: Self.visible)
        #expect(frame.maxX == 1440 - PanelPresentation.screenMargin)
        #expect(frame.width == 310)
    }

    @Test func onASecondScreenItUsesThatScreen() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1056)
        let item = CGRect(x: 2900, y: 1056, width: 28, height: 24)
        let frame = PanelPresentation.frame(contentSize: Self.size, item: item, visible: second)
        #expect(frame.minX == 2900)
        #expect(frame.maxY == 1056 - PanelPresentation.gapBelowMenuBar)
    }

    @Test func aTallPanelNeverRunsOffTheBottom() {
        let item = CGRect(x: 100, y: 876, width: 28, height: 24)
        let frame = PanelPresentation.frame(contentSize: CGSize(width: 310, height: 2000), item: item, visible: Self.visible)
        #expect(frame.minY >= Self.visible.minY)
        #expect(frame.maxY == 876 - PanelPresentation.gapBelowMenuBar)
    }
}
