import CoreGraphics
import Foundation
import Testing
import ObscuraPrefs
@testable import ObscuraThumbnailUI

/// Click, drag, fling, swipe, the menu, capsule words and placement.
@Suite struct ThumbnailDecisionTests {
    static let file = URL(fileURLWithPath: "/home/example/Desktop/Screenshot 2026-10-26 at 9.41.12 AM.png")
    static let id = UUID()
    static let covered = CardPhase.covered(entryID: id, findings: 2)
    static let original = CardPhase.original(entryID: id, findings: 2)

    // MARK: Click

    @Test func clickOpensPreviewOrTheViewerPerSettings() {
        #expect(ClickTarget.resolve(phase: .checking, setting: .preview, file: Self.file) == .nothing)
        #expect(ClickTarget.resolve(phase: .clean, setting: .preview, file: Self.file) == .preview(Self.file))
        #expect(ClickTarget.resolve(phase: .clean, setting: .viewer, file: Self.file) == .preview(Self.file),
                "a clean shot has no Journal entry for the viewer")
        #expect(ClickTarget.resolve(phase: Self.covered, setting: .preview, file: Self.file) == .preview(Self.file))
        #expect(ClickTarget.resolve(phase: Self.covered, setting: .viewer, file: Self.file) == .viewer(Self.id))
        #expect(ClickTarget.resolve(phase: Self.original, setting: .viewer, file: nil) == .viewer(Self.id))
        #expect(ClickTarget.resolve(phase: Self.covered, setting: .preview, file: nil) == .nothing)
    }

    // MARK: Drag

    @Test func theDragCarriesTheCleanFileUnderItsOnDiskName() {
        let all: (URL) -> Bool = { _ in true }
        #expect(DragFile.resolve(phase: .checking, fileURL: Self.file, entryFilePath: nil, entryCleanCopyPath: nil, exists: all) == nil,
                "refused while checking")
        #expect(DragFile.resolve(phase: .clean, fileURL: Self.file, entryFilePath: nil, entryCleanCopyPath: nil, exists: all) == Self.file)
        // Replace mode: the screenshot itself was overwritten with the clean image.
        #expect(DragFile.resolve(phase: Self.covered, fileURL: Self.file, entryFilePath: Self.file.path, entryCleanCopyPath: nil,
                                 exists: all) == Self.file)
        // Keep-both mode: the " (clean)" sibling.
        let sibling = "/home/example/Desktop/Screenshot 2026-10-26 at 9.41.12 AM (clean).png"
        #expect(DragFile.resolve(phase: Self.covered, fileURL: Self.file, entryFilePath: Self.file.path, entryCleanCopyPath: sibling,
                                 exists: all)?.lastPathComponent == "Screenshot 2026-10-26 at 9.41.12 AM (clean).png")
        // After Undo the card carries the screenshot, which holds the original, as the red marks announce; in keep-both
        // mode the " (clean)" sibling went to the Trash with the Undo and is never what an original card carries (#17).
        #expect(DragFile.resolve(phase: Self.original, fileURL: Self.file, entryFilePath: Self.file.path, entryCleanCopyPath: sibling,
                                 exists: all) == Self.file)
        #expect(DragFile.resolve(phase: Self.original, fileURL: Self.file, entryFilePath: Self.file.path, entryCleanCopyPath: nil,
                                 exists: all) == Self.file)
        #expect(DragFile.resolve(phase: .clean, fileURL: Self.file, entryFilePath: nil, entryCleanCopyPath: nil, exists: { _ in false }) == nil,
                "a file that is gone is never offered")
    }

    @Test func aDropOrAFlingPastTheRightEdgeDismisses() {
        let card = CGRect(x: 1248, y: 96, width: 176, height: 110)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(DragEnd.dismisses(dropped: true, endPoint: CGPoint(x: 300, y: 500), cardFrame: card, screen: screen))
        #expect(!DragEnd.dismisses(dropped: false, endPoint: CGPoint(x: 1300, y: 150), cardFrame: card, screen: screen),
                "let go over itself: it comes back")
        #expect(DragEnd.dismisses(dropped: false, endPoint: CGPoint(x: 1430, y: 150), cardFrame: card, screen: screen))
        #expect(!DragEnd.dismisses(dropped: false, endPoint: CGPoint(x: 1700, y: 150), cardFrame: card, screen: screen),
                "past the edge onto a display to the right is a failed drop, not a fling (S-22)")
    }

    @Test func aTwoFingerSwipeRightDismissesPastTheDistanceOrOnAFling() {
        var s = SwipeTracker()
        s.changed(by: 10); s.changed(by: 10)
        #expect(!s.shouldDismiss)
        s.changed(by: 30)
        #expect(s.shouldDismiss)

        var fling = SwipeTracker()
        fling.changed(by: 4); fling.changed(by: 14)
        #expect(fling.shouldDismiss)

        var timed = SwipeTracker()
        timed.changed(by: 10, at: 1.0)
        timed.changed(by: 20, at: 1.25)
        #expect(timed.speed == 80, "points per second from the last two events")
        timed.reset()
        #expect(timed.speed == 0)

        var left = SwipeTracker()
        left.changed(by: -40)
        #expect(left.offset == -SwipeTracker.leftRubberBand)
        #expect(!left.shouldDismiss)
    }

    // MARK: Menu

    @Test func theMenuFollowsR3aAndOffersNothingUnscanned() {
        #expect(ThumbnailMenuItem.items(for: .checking, clickOpens: .preview) == [.close])
        #expect(ThumbnailMenuItem.items(for: .clean, clickOpens: .preview) == [.copy, .showInFinder, .separator, .delete, .close])
        #expect(ThumbnailMenuItem.items(for: .clean, clickOpens: .viewer) == [.copy, .openInPreview, .showInFinder, .separator, .delete, .close])
        #expect(ThumbnailMenuItem.items(for: Self.covered, clickOpens: .preview)
                == [.copy, .openInViewer, .showInFinder, .openInJournal, .separator, .undo, .separator, .delete, .close])
        #expect(ThumbnailMenuItem.items(for: Self.original, clickOpens: .viewer)
                == [.copy, .openInPreview, .showInFinder, .openInJournal, .separator, .blackOutAgain, .separator, .delete, .close])
    }

    @Test func menuWordsMatchTheMockup() {
        #expect(ThumbnailMenuLook(.copy, phase: Self.covered).subtitle == "The clean image")
        #expect(ThumbnailMenuLook(.undo, phase: Self.covered).title == "Undo (Show Original)")
        #expect(ThumbnailMenuLook(.undo, phase: Self.covered).subtitle == "Puts the original back on disk")
        #expect(ThumbnailMenuLook(.openInViewer, phase: Self.covered).title == "Open in Obscura Viewer")
        #expect(ThumbnailMenuLook(.delete, phase: Self.covered).destructive)
    }

    // MARK: Capsule

    @Test func capsulesDifferByGlyphAndWords() {
        #expect(ThumbnailCopy.covered(2) == "2 covered")
        #expect(ThumbnailCopy.checked == "Checked")
        #expect(ThumbnailCopy.checking == "Checking…")
        #expect(ThumbnailCopy.accessibilityValue(.covered(1)) == "1 secret covered")
        #expect(ThumbnailCopy.accessibilityValue(.original(2)) == "Original showing, 2 secrets visible")
        #expect(CapsuleKind.original(2).marksOriginal)
        #expect(!CapsuleKind.covered(2).marksOriginal)
        #expect(HoverAction(Self.covered) == .undo)
        #expect(HoverAction(.clean) == nil)
        #expect(HoverAction(.checking) == nil)
    }

    // MARK: Placement

    @Test func theCardSitsSixteenPointsFromTheBottomRight() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 820)
        let card = ThumbnailPlacement.cardFrame(in: visible)
        #expect(card == CGRect(x: 1440 - 16 - 176, y: 96, width: 176, height: 110))
        let panel = ThumbnailPlacement.panelFrame(in: visible)
        #expect(panel.size == ThumbnailPlacement.panelSize)
        #expect(panel.minX == card.minX - ThumbnailPlacement.marginSide)
        #expect(panel.maxY == card.maxY + ThumbnailPlacement.marginTop)
    }

    @Test func theWindowEndsAtTheDisplaysEdgeSoTheSlideIsClippedThere() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 820)
        let window = ThumbnailPlacement.windowFrame(in: visible, screen: screen)
        #expect(window.maxX == screen.maxX, "never reaches a display arranged to the right (S-4)")
        let area = ThumbnailPlacement.panelFrame(in: visible)
        #expect(window.contains(area))
        #expect(window.minX == area.minX - ThumbnailPlacement.shadowPadSide, "room for the card's own shadow")
        #expect(window.minY >= screen.minY)
        let inWindow = ThumbnailPlacement.areaRect(in: visible, window: window)
        #expect(inWindow.size == ThumbnailPlacement.panelSize)
        #expect(inWindow.origin == CGPoint(x: area.minX - window.minX, y: area.minY - window.minY))
        #expect(ThumbnailPlacement.slideDistance(window: window) >= window.maxX - area.minX, "fully outside, shadow included")

        // A display arranged to the right of the main one: the window stays on its own display.
        let right = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let rightWindow = ThumbnailPlacement.windowFrame(in: right, screen: right)
        #expect(rightWindow.maxX == right.maxX)
        #expect(rightWindow.minX >= right.minX)
    }

    @Test func aSwipedCardLeavesAtTheFingersSpeed() {
        #expect(SwipeExit.duration(remaining: 200, speed: 2000, slide: 0.2) == 0.1)
        #expect(SwipeExit.duration(remaining: 200, speed: 100, slide: 0.2) == 0.2, "never slower than the slide")
        #expect(SwipeExit.duration(remaining: 200, speed: 100_000, slide: 0.2) == SwipeExit.shortest)
        #expect(SwipeExit.duration(remaining: 200, speed: 0, slide: 0.2) == 0.2)
        #expect(SwipeExit.duration(remaining: 0, speed: 500, slide: 0.2) == 0)
    }

    @Test func itShowsOnTheScreenThatHeldThePointer() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 2560, height: 1440)]
        #expect(ThumbnailPlacement.screenIndex(containing: CGPoint(x: 2000, y: 700), frames: frames) == 1)
        #expect(ThumbnailPlacement.screenIndex(containing: CGPoint(x: 100, y: 100), frames: frames) == 0)
        #expect(ThumbnailPlacement.screenIndex(containing: CGPoint(x: 4000, y: 1440), frames: frames) == 1, "the far corner")
        #expect(ThumbnailPlacement.screenIndex(containing: .zero, frames: []) == nil)
    }
}
