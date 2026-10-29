import Testing
import Foundation
import CoreGraphics
@testable import ObscuraViewerUI
import ObscuraUIKit

/// BadgeLayout.place: badges anchored to their bars, never over another bar or badge, inside the image.
@Suite struct BadgeLayoutTests {
    private let badge = CGSize(width: 18, height: 18)

    private func item(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, covered: Bool = true, badge: CGSize? = nil) -> BadgeLayout.Item {
        BadgeLayout.Item(rect: CGRect(x: x, y: y, width: w, height: h), badgeSize: badge ?? self.badge, covered: covered)
    }

    private func area(_ a: CGRect, _ b: CGRect) -> CGFloat { BadgeLayout.overlap(a, b) }

    /// The invariants every clear layout keeps: inside the image, off every other bar, off every other badge, and off
    /// its own text when the finding is left visible.
    private func expectClear(_ placements: [BadgeLayout.Placement], _ items: [BadgeLayout.Item], image: CGSize,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let bounds = CGRect(origin: .zero, size: image)
        #expect(placements.count == items.count, sourceLocation: sourceLocation)
        for (i, p) in placements.enumerated() {
            #expect(p.isClear, "badge \(i + 1) found a clear spot", sourceLocation: sourceLocation)
            #expect(bounds.contains(p.frame), "badge \(i + 1) inside the image", sourceLocation: sourceLocation)
            #expect(p.frame.size == items[i].badgeSize, sourceLocation: sourceLocation)
            for (j, other) in items.enumerated() where j != i {
                #expect(area(p.frame, other.rect) == 0, "badge \(i + 1) is off bar \(j + 1)", sourceLocation: sourceLocation)
            }
            for (j, q) in placements.enumerated() where j > i {
                #expect(area(p.frame, q.frame) == 0, "badges \(i + 1) and \(j + 1) do not overlap", sourceLocation: sourceLocation)
            }
            if !items[i].covered {
                #expect(area(p.frame, items[i].rect) == 0, "badge \(i + 1) leaves its visible text readable", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func aBarBigEnoughHoldsItsBadgeAtItsLeadingEnd() {
        let items = [item(200, 50, 300, 20), item(200, 100, 300, 60)]
        let p = BadgeLayout.place(imageSize: CGSize(width: 800, height: 300), items: items, gap: 6, inset: 3)
        expectClear(p, items, image: CGSize(width: 800, height: 300))
        #expect(p.map(\.anchor) == [.onBar, .onBar])
        // Centred in the thin bar, tucked into the top corner of the tall one.
        #expect(p[0].frame == CGRect(x: 203, y: 51, width: 18, height: 18))
        #expect(p[1].frame == CGRect(x: 203, y: 103, width: 18, height: 18))
        #expect(items[0].rect.contains(p[0].frame) && items[1].rect.contains(p[1].frame))
    }

    @Test func neverLeftOfTheBarWhereTheKeyNameIs() {
        // `KEY=value` lines: the bar starts after the key, so the badge never goes into the leading gutter.
        let items = [item(200, 50, 300, 12), item(200, 80, 300, 12, covered: false)]
        let p = BadgeLayout.place(imageSize: CGSize(width: 800, height: 300), items: items, gap: 6, inset: 3)
        expectClear(p, items, image: CGSize(width: 800, height: 300))
        #expect(p.map(\.anchor) == [.trailing, .trailing])
        #expect(p[0].frame.minX == 506 && p[0].frame.midY == items[0].rect.midY)
        for (i, pl) in p.enumerated() { #expect(pl.frame.minX >= items[i].rect.maxX) }
    }

    @Test func aLeftVisibleFindingKeepsItsTextReadable() {
        // Its bar is gone and its text shows, so the badge never sits on it even when it would fit.
        let items = [item(200, 50, 300, 40, covered: false)]
        let p = BadgeLayout.place(imageSize: CGSize(width: 800, height: 300), items: items, gap: 6, inset: 3)
        expectClear(p, items, image: CGSize(width: 800, height: 300))
        #expect(p[0].anchor == .trailing)
    }

    @Test func aBarAtTheRightEdgeGoesAboveAndThenBelow() {
        let image = CGSize(width: 500, height: 300)
        let above = [item(200, 100, 300, 12)]
        let p = BadgeLayout.place(imageSize: image, items: above, gap: 6, inset: 3)
        expectClear(p, above, image: image)
        #expect(p[0].anchor == .above)
        #expect(p[0].frame.maxX == 500 && p[0].frame.maxY == 94)
        // At the top edge too: below.
        let below = [item(200, 0, 300, 12)]
        let q = BadgeLayout.place(imageSize: image, items: below, gap: 6, inset: 3)
        expectClear(q, below, image: image)
        #expect(q[0].anchor == .below)
    }

    @Test func aTinyBarPutsItsBadgeBesideIt() {
        // A three-digit code at low zoom: the bar is smaller than the badge.
        let items = [item(100, 100, 10, 6)]
        let p = BadgeLayout.place(imageSize: CGSize(width: 400, height: 300), items: items, gap: 2, inset: 1)
        expectClear(p, items, image: CGSize(width: 400, height: 300))
        #expect(p[0].anchor == .trailing)
        #expect(p[0].frame.minX == 112)
    }

    @Test func aDenseStackSlidesInsteadOfOverlapping() {
        // 12 rows of tiny bars 14 apart, badges taller than the rows, and a second column right beside the first:
        // trailing spots collide row to row and with the next column, so most badges slide along the row.
        var items: [BadgeLayout.Item] = []
        for row in 0..<12 {
            items.append(item(40, 20 + CGFloat(row) * 14, 120, 12))
            items.append(item(170, 20 + CGFloat(row) * 14, 80, 12, covered: row % 3 != 0))
        }
        let image = CGSize(width: 900, height: 220)
        let p = BadgeLayout.place(imageSize: image, items: items, gap: 2, inset: 1)
        expectClear(p, items, image: image)
        #expect(p.contains { $0.anchor == .slid })
        // Badge 1 had first pick and took its first choice.
        #expect(p[0].anchor == .trailing || p[0].anchor == .above)
    }

    @Test func withNoClearSpotItHidesTheLeastAndStaysInside() {
        // One bar fills the image and a second sits on top of it: nowhere is clear.
        let image = CGSize(width: 100, height: 40)
        let items = [item(0, 0, 100, 40, covered: false), item(10, 10, 80, 20, covered: false)]
        let p = BadgeLayout.place(imageSize: image, items: items, gap: 2, inset: 1)
        #expect(p.count == 2)
        for pl in p {
            #expect(pl.anchor == .leastHidden && !pl.isClear)
            #expect(CGRect(origin: .zero, size: image).contains(pl.frame))
        }
    }

    @Test func degenerateInputsDoNotTrap() {
        #expect(BadgeLayout.place(imageSize: CGSize(width: 100, height: 100), items: [], gap: 2, inset: 1).isEmpty)
        let p = BadgeLayout.place(imageSize: .zero, items: [item(0, 0, 0, 0)], gap: 0, inset: 0)
        #expect(p.count == 1)
        // A badge bigger than the image is pinned to its top-left corner.
        let big = BadgeLayout.place(imageSize: CGSize(width: 10, height: 10), items: [item(2, 2, 4, 4)], gap: 1, inset: 1)
        #expect(big[0].frame.origin == .zero)
    }

    @Test func everyMarkAroundAFindingClearsItsLetters() {
        // A finding's box hugs its glyphs (ink cells), so each stroke's inner edge must sit outside the box, each ring
        // outside the one before it, and the badges clear of the outermost ring (live check 2026-10-27).
        let stroke: CGFloat = 1.5, hoverStroke: CGFloat = 2
        #expect(FindingMarksView.outlineGap - stroke / 2 >= 2)
        #expect(FindingMarksView.ringGap - stroke / 2 >= FindingMarksView.outlineGap + stroke / 2)
        #expect(FindingMarksView.hoverGap - hoverStroke / 2 >= FindingMarksView.ringGap + stroke / 2)
        #expect(FindingMarksView.badgeGap >= FindingMarksView.hoverGap + hoverStroke / 2)
    }

    @Test func theSampleTerminalNeverHasABadgeOverAKeyName() {
        // The seeded `.env` screenshot at the viewer's fit zoom, at 1×, 2× and zoomed far in, with one left visible.
        let layout = SampleData.TerminalLayout()
        let findings = SampleData.terminalFindings(layout: layout, leftVisible: [3])
        let image = layout.pixelSize
        for m: CGFloat in [0.35, 0.5, 1, 2, 8] {
            let d = FindingMarksView.badgeDiameter / m
            let items = findings.map { BadgeLayout.Item(rect: $0.rect, badgeSize: CGSize(width: d, height: d), covered: $0.enabled) }
            let p = BadgeLayout.place(imageSize: image, items: items, gap: FindingMarksView.badgeGap / m, inset: FindingMarksView.badgeInset / m)
            expectClear(p, items, image: image)
            for (i, pl) in p.enumerated() {
                #expect(pl.frame.minX >= items[i].rect.minX, "badge \(i + 1) at \(m)× is not in the key-name gutter")
            }
        }
    }
}
