// G-22: a reading judged against its ink (ReadCoverage), and the duplicate fragments Vision returns on a strip
// (TileStitcher.distinct). Pure, synthetic geometry, no Vision.
import CoreGraphics
import Foundation
import Testing
@testable import ObscuraOCR

private func observation(_ text: String, x: CGFloat, advance: CGFloat = 10) -> OCRLine {
    let n = text.utf16.count
    return OCRLine(index: 0, text: text, rect: CGRect(x: x, y: 0, width: CGFloat(n) * advance, height: 20),
                   candidate: CharacterBoxes(boxes: (0..<n).map { CGRect(x: x + CGFloat($0) * advance, y: 0, width: advance, height: 20) }))
}

/// `cells` ink cells on a 10 px grid from x = 100.
private func profile(cells: Int) -> InkProfile {
    InkProfile(boxes: (0..<cells).map { CGRect(x: 101 + CGFloat($0) * 10, y: 4, width: 8, height: 12) }, advance: 10, isGrid: true)
}

@Suite("Short reads (G-22)")
struct ShortReadTests {
    let token = "Ab3dEfGh1JkLmN0pQrStUvWxYz2a4c6e8g0iKmOqSuWy"

    @Test func aDuplicateFragmentInsideALongerReadingIsDroppedAndASplitIsKept() {
        let full = observation(token, x: 100)
        let fragment = observation(String(token.prefix(12)), x: 98)
        #expect(TileStitcher.distinct([fragment, full]).map(\.text) == [token])
        #expect(TileStitcher.run(of: [fragment, full]).text == token)
        let left = observation(String(token.prefix(20)), x: 100), right = observation(String(token.suffix(20)), x: 340)
        #expect(TileStitcher.distinct([left, right]).count == 2)
    }

    @Test func aWholeReadingIsNotShortAndAReadingWithAHoleIs() {
        let ink = profile(cells: token.utf16.count)
        let tuning = RecallTuning()
        let whole = ReadCoverage.count(TileStitcher.run(of: [observation(token, x: 100)]), profile: ink, span: -.infinity...(.infinity))
        #expect(whole == ReadCount(units: 44, ink: 44, uncovered: 0, isGrid: true) && !whole.isShort(tuning))
        // Two pieces with 14 cells between them nobody read.
        let holed = ReadCoverage.count(TileStitcher.run(of: [observation(String(token.prefix(15)), x: 100), observation(String(token.suffix(15)), x: 390)]),
                                       profile: ink, span: -.infinity...(.infinity))
        #expect(holed.units == 30 && holed.uncovered == 14 && holed.isShort(tuning))
    }

    @Test func theToleranceAbsorbsTwoDroppedGlyphsButNotFour() {
        let tuning = RecallTuning()
        #expect(!ReadCount(units: 42, ink: 44, uncovered: 0, isGrid: true).isShort(tuning))
        #expect(ReadCount(units: 40, ink: 44, uncovered: 0, isGrid: true).isShort(tuning))
        // Without a grid ink boxes are word runs: only uncovered ink counts.
        #expect(!ReadCount(units: 10, ink: 44, uncovered: 0, isGrid: false).isShort(tuning))
        // A long line's tolerance grows with it (3 % of 322 ink cells is 9.66).
        #expect(!ReadCount(units: 313, ink: 322, uncovered: 0, isGrid: true).isShort(tuning))
        #expect(ReadCount(units: 236, ink: 322, uncovered: 0, isGrid: true).isShort(tuning))
    }

    @Test func aTileIsJudgedWithoutTheGlyphItsInnerEdgeCuts() {
        let band = CGRect(x: 0, y: 0, width: 1000, height: 20)
        #expect(ReadCoverage.judgedSpan(tile: CGRect(x: 0, y: 0, width: 400, height: 20), band: band, advance: 10) == -.infinity...390)
        #expect(ReadCoverage.judgedSpan(tile: CGRect(x: 300, y: 0, width: 400, height: 20), band: band, advance: 10) == 310...690)
        #expect(ReadCoverage.judgedSpan(tile: CGRect(x: 600, y: 0, width: 400, height: 20), band: band, advance: 10) == 610...(.infinity))
    }

    @Test func theInkEndChainsAcrossASpaceAndStopsAtAColumnGap() {
        // Cells 0–9 ink, cell 10 blank (a space), cells 11–19 ink, then a 6-cell gap and another column at 26–30.
        let cells = Array(0..<10) + Array(11..<20) + Array(26..<31)
        let ink = cells.map { CGRect(x: 101 + CGFloat($0) * 10, y: 4, width: 8, height: 12) }
        let short = ShortRead(band: 0, count: ReadCount(units: 5, ink: ink.count, uncovered: 0, isGrid: true), ink: ink, advance: 10)
        #expect(abs(short.inkEnd(from: 150, start: 100) - (101 + 19 * 10 + 8)) < 0.001)
        #expect(short.inkEnd(from: 420, start: 100) == 420)
    }
}
