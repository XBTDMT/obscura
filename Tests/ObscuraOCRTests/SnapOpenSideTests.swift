// Fail-open #16: snapping a cover to the glyph grid counts cells from the characters the read returned. When the read
// dropped more characters than the word-run match tolerates, the snapped cover ended inside the token's own ink while
// the pre-snap box (Vision's word box, which spans the ink) reached its end. On a side where the token ends at its word's
// edge (an open side: whitespace or the line's end, never a key name), the snapped cover now never ends before the
// pre-snap box's run of ink. Every value is made up.
import CoreGraphics
import Foundation
import Testing
@testable import ObscuraOCR

@Suite("Grid snap never ends inside the pre-snap ink run (fail-open #16)")
struct SnapOpenSideTests {
    static let advance: CGFloat = 10, x0: CGFloat = 100

    /// One ink box per non-space character of `truth` on a 10 px grid from x = 100: letters and digits 8 px wide across
    /// the row's middle, `"` a narrow tick above it, `,` a narrow tick below it, `_` a wide bar below it.
    static func ink(_ truth: String) -> [CGRect] {
        truth.enumerated().compactMap { i, c in
            let x = x0 + CGFloat(i) * advance
            switch c {
            case " ": return nil
            case "\"": return CGRect(x: x + 3, y: 2, width: 4, height: 5)
            case ",": return CGRect(x: x + 4, y: 14, width: 2, height: 5)
            case "_": return CGRect(x: x + 1, y: 15, width: 8, height: 2)
            default: return CGRect(x: x + 1, y: 4, width: 8, height: 12)
            }
        }
    }

    /// Vision's word geometry: any range answers the box of the drawn word (in `truth`) it falls in. The read text and
    /// the drawing have the same words in the same order, only shorter where characters were dropped.
    struct DrawnWords: GlyphBoxProvider {
        let read: String
        let truth: String
        func boundingBox(forUTF16Range range: NSRange) -> CGRect? {
            let readWords = SnapOpenSideTests.words(read), drawn = SnapOpenSideTests.words(truth)
            guard let index = readWords.firstIndex(where: { NSLocationInRange(range.location, $0) }), index < drawn.count else { return nil }
            let word = drawn[index]
            return CGRect(x: x0 + CGFloat(word.location) * advance, y: 2, width: CGFloat(word.length) * advance, height: 16)
        }
    }

    static func words(_ text: String) -> [NSRange] {
        let units = Array(text.utf16)
        var result: [NSRange] = []
        var start: Int?
        for (i, u) in units.enumerated() {
            if u == 0x20 { if let s = start { result.append(NSRange(location: s, length: i - s)); start = nil } } else if start == nil { start = i }
        }
        if let s = start { result.append(NSRange(location: s, length: units.count - s)) }
        return result
    }

    func line(read: String, truth: String) -> OCRLine {
        OCRLine(index: 0, text: read, rect: CGRect(x: Self.x0, y: 2, width: CGFloat(truth.utf16.count) * Self.advance, height: 16),
                candidate: DrawnWords(read: read, truth: truth), glyphBoxes: Self.ink(truth))
    }

    /// The x range of glyph `i` of the drawing.
    func glyph(_ i: Int) -> CGRect { CGRect(x: Self.x0 + CGFloat(i) * Self.advance + 1, y: 4, width: 8, height: 12) }

    @Test func aTokenTheReadShortenedByFiveGlyphsIsStillCoveredToItsLastGlyph() throws {
        let truth = "token = a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5 end"
        let read = "token = a1B2c3D47H8i9J0k1L2m3N4o5 end"                       // `e5F6g` dropped: 25 of 30 glyphs
        let l = line(read: read, truth: truth)
        try #require(GlyphGrid.fit(l.glyphBoxes, lineHeight: l.rect.height) != nil)
        let token = (read as NSString).range(of: "a1B2c3D47H8i9J0k1L2m3N4o5")
        let cover = BoxMapper.rect(forUTF16Range: token, in: l)
        let first = (truth as NSString).range(of: "a1B2").location, last = (truth as NSString).range(of: " end").location - 1
        #expect(cover.minX <= glyph(first).minX && cover.maxX >= glyph(last).maxX,
                "cover \(cover.minX)…\(cover.maxX) must span \(glyph(first).minX)…\(glyph(last).maxX)")
        // Neither the `=` before it nor the word after it.
        let equals = (truth as NSString).range(of: "=").location, end = (truth as NSString).range(of: "end").location
        #expect(!cover.intersects(glyph(equals)) && !cover.intersects(glyph(end)))
    }

    @Test func aKeyNameOnTheClosedSideIsNeverTaken() throws {
        // `KEY=value`: the token's left side is the `=` inside its word, a closed side; the right side ends the line.
        let truth = "API_KEY=q9W8e7R6t5Y4u3I2o1P0a9S8d7F6"
        let read = "API_KEY=q9W8e7R6t5Y4u3I2a9S8d7F6"                               // `o1P0` dropped: 24 of 28 glyphs
        let l = line(read: read, truth: truth)
        let token = (read as NSString).range(of: "q9W8e7R6t5Y4u3I2a9S8d7F6")
        let cover = BoxMapper.rect(forUTF16Range: token, in: l)
        #expect(cover.maxX >= glyph(truth.utf16.count - 1).maxX)
        for i in 0..<7 { #expect(!cover.intersects(glyph(i)), "key glyph \(i) touched") }
    }

    /// Measured on scm.rubygems.key: the read dropped a JSON value's closing `",`, so the token seemed to end at its
    /// word's edge. The quote and comma are the value's framing, not dropped token glyphs: the cover stops before them.
    @Test func aDroppedClosingQuoteAndCommaAreNotTakenIntoTheCover() throws {
        let truth = #"  "k": "rubygems_0a1b2c3d4e5f6a7b8c9d0e1f","#
        let read = #"  "k": "rubygems_0a1b2c3d4e5f6a7b8c9d0e1f"#
        let l = line(read: read, truth: truth)
        let token = (read as NSString).range(of: "rubygems_0a1b2c3d4e5f6a7b8c9d0e1f")
        let cover = BoxMapper.rect(forUTF16Range: token, in: l)
        let last = NSMaxRange(token) - 1
        #expect(cover.maxX >= glyph(last).maxX, "the token's last glyph")
        let comma = CGRect(x: Self.x0 + CGFloat(last + 2) * Self.advance + 4, y: 14, width: 2, height: 5)
        #expect(!cover.intersects(comma), "the comma")
        #expect(cover.maxX < Self.x0 + CGFloat(last + 1) * Self.advance + 5, "at most into the closing quote's cell")
    }

    @Test func aFaithfulReadKeepsItsSnappedCover() throws {
        let truth = "token = a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5 end"
        let l = line(read: truth, truth: truth)
        let token = (truth as NSString).range(of: "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5")
        let cover = BoxMapper.rect(forUTF16Range: token, in: l)
        // The grid cover: cells 8…37 with a tenth of an advance of slack each side.
        #expect(abs(cover.minX - (Self.x0 + 8 * Self.advance - 1)) < 0.01 && abs(cover.maxX - (Self.x0 + 38 * Self.advance + 1)) < 0.01)
    }
}
