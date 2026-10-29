// G-40: the spot viewer. Each spot is outlined (waiting ones in the needs tone, settled ones quiet), Not Text and Cover
// It act on the spots still waiting, Cover It needs the file, and the outline sits just outside the spot. Drawn by the
// window's own views through ViewSnapshot. Every rect and name is made up.
import AppKit
import SwiftUI
import Testing
import ObscuraCapture
import ObscuraEngine
import ObscuraJournal
import ObscuraTestSupport
import ObscuraUIKit
@testable import ObscuraViewerUI

@MainActor
@Suite struct SpotReviewTests {
    static func file(_ states: [SpotState]) -> UncheckedFile {
        let url = URL(fileURLWithPath: "/home/example/Downloads/photo.png")
        let spots = states.enumerated().map { i, state in
            SpotRecord(rect: CGRect(x: 100 + 80 * CGFloat(i), y: 50, width: 40, height: 8), coverRect: CGRect(x: 92, y: 42, width: 56, height: 24), state: state)
        }
        return UncheckedFile(key: CaptureKey(file: url), displayName: "photo.png", fileURL: url, origin: .downloads,
                             reason: UncheckedReason.unreadPatch.rawValue, date: Date(), spots: spots)
    }

    @Test func aWaitingSpotIsOutlinedWithBothAnswers() {
        let shown = SpotReviewContent(file: Self.file([.pending]), fileExists: true)
        #expect(shown.title == "photo.png")
        #expect(shown.lead == "Obscura couldn't read the outlined spot. It may be a mark, not text. Look closely before you share it.")
        #expect(shown.outlines.map(\.rect) == [CGRect(x: 100, y: 50, width: 40, height: 8)])
        #expect(shown.outlines.map(\.tone) == [.needs] && shown.outlines.map(\.label) == ["Waiting for you"])
        #expect(shown.showsActions && shown.canCover)
    }

    @Test func settledSpotsStayOutlinedQuietlyWithNoAnswers() {
        let shown = SpotReviewContent(file: Self.file([.notText, .covered, .tooSmall]), fileExists: true)
        #expect(shown.lead == "Every spot in this picture is settled.")
        #expect(shown.outlines.count == 3 && shown.outlines.allSatisfy { $0.tone == .quiet })
        #expect(shown.outlines.map(\.label) == ["You said it isn't text", "Covered", "Skipped: too small to hold a secret"])
        #expect(!shown.showsActions)
    }

    @Test func twoWaitingSpotsAreCountedAndAMissingFileCanOnlyBeMarkedNotText() {
        let shown = SpotReviewContent(file: Self.file([.pending, .pending]), fileExists: false)
        #expect(shown.lead == "Obscura couldn't read the 2 outlined spots. They may be marks, not text. Look closely before you share it.")
        #expect(shown.showsActions && !shown.canCover)
    }

    @Test func theOutlineSitsJustOutsideTheSpotAtAnyScale() {
        let rect = CGRect(x: 100, y: 50, width: 40, height: 8)
        #expect(SpotReviewContent.frame(rect, pixelSize: CGSize(width: 480, height: 120), drawn: CGSize(width: 240, height: 60), gap: 3)
                == CGRect(x: 47, y: 22, width: 26, height: 10))
        #expect(SpotReviewContent.frame(rect, pixelSize: .zero, drawn: CGSize(width: 10, height: 10), gap: 3) == .zero)
        #expect(SpotReviewWindow.fitted(CGSize(width: 2640, height: 1240), in: CGSize(width: 688, height: 400)).width <= 688)
        #expect(SpotReviewWindow.fitted(CGSize(width: 100, height: 50), in: CGSize(width: 688, height: 400)) == CGSize(width: 100, height: 50),
                "never enlarged")
    }

    @Test func theCatchViewersStripSaysWhatWaitsOrHowItWasSettled() {
        #expect(SpotStrip.words(Self.file([.pending])) == "1 spot couldn't be read · Obscura couldn't read the outlined spot. It may be a mark, not text. Look closely before you share it.")
        #expect(SpotStrip.words(Self.file([.covered])) == "Covered")
        #expect(SpotStrip.words(Self.file([.tooSmall, .tooSmall])) == "2 spots skipped: too small to hold a secret")
        #expect(SpotStrip.words(Self.file([.notText, .covered])) == "2 spots settled")
    }

    @Test func theOutlineAndTheStripDraw() throws {
        let outline = NSHostingView(rootView: SpotOutline(tone: .needs).frame(width: 60, height: 20).padding(6))
        outline.frame = CGRect(x: 0, y: 0, width: 72, height: 32)
        let bitmap = try #require(ViewSnapshot.bitmap(outline))
        #expect(bitmap.pixelsWide > 0)
        var tinted = 0
        for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { tinted += 1 } }
        #expect(tinted > 40, "the outline is drawn")
        let strip = NSHostingView(rootView: SpotStrip(row: Self.file([.pending])) {}.frame(width: 720))
        strip.frame = CGRect(x: 0, y: 0, width: 720, height: 40)
        #expect(ViewSnapshot.bitmap(strip) != nil)
    }
}
