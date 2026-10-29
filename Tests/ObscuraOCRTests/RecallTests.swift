// G-12 routes A and B and the cover geometry: pure functions on synthetic observations, no Vision.
import CoreGraphics
import Foundation
import Testing
@testable import ObscuraOCR

/// Lines of monospace text with a 10 px advance and 20 px height, starting at x = 100.
private func mono(_ index: Int, _ text: String, x: CGFloat = 100, y: CGFloat = 0, advance: CGFloat = 10) -> OCRLine {
    let n = CGFloat(text.utf16.count)
    return OCRLine(index: index, text: text, rect: CGRect(x: x, y: y, width: n * advance, height: 20),
                   candidate: CharacterBoxes(boxes: (0..<text.utf16.count).map { CGRect(x: x + CGFloat($0) * advance, y: y, width: advance, height: 20) }))
}

@Suite("Re-read selection (routes A and B)")
struct RereadPlannerTests {
    let size = CGSize(width: 4000, height: 400)

    @Test func aShortCleanLineIsNotReread() {
        let line = mono(0, "PORT=8080")
        let region = TextRegion(rect: line.rect)
        #expect(RereadPlanner.plan(lines: [line], regions: [region], imageSize: size, labelLines: []).isEmpty)
    }

    @Test func aLongLineIsRereadInOverlappingTiles() throws {
        let line = mono(0, String(repeating: "Ab3dE", count: 60))          // 300 characters, 3,000 px
        let bands = RereadPlanner.plan(lines: [line], regions: [], imageSize: size, labelLines: [])
        let band = try #require(bands.first)
        #expect(bands.count == 1)
        #expect(band.reasons == [.long])
        #expect(band.replaces == [0])
        #expect(band.tiles.count >= 3)
        for (a, b) in zip(band.tiles, band.tiles.dropFirst()) { #expect(a.maxX > b.minX) }          // they overlap
        #expect(band.tiles.first!.minX <= band.rect.minX && band.tiles.last!.maxX >= band.rect.maxX - 1)
        #expect(abs(band.scale - 2.4) < 0.001)                                                      // 20 px line → 48 px target, ≤ 3×
    }

    @Test func aLineThatEndsBeforeItsInkIsReread() {
        let line = mono(0, "aws_session_token = Dys/ge3yvy1Ix8")
        let region = TextRegion(rect: CGRect(x: 100, y: 0, width: 3000, height: 20))
        let triggers = RereadPlanner.lineTriggers(lines: [line], regions: [region], labelLines: [])
        #expect(triggers[0] == [.endsEarly])
    }

    @Test func twoObservationsThatNearlyTouchAreOneSplitLine() {
        let left = mono(0, "https://discord.com/api/webhooks/1234", x: 100)
        let right = mono(1, "abcdefgh", x: left.rect.maxX + 5)
        let bands = RereadPlanner.plan(lines: [left, right], regions: [], imageSize: size, labelLines: [])
        #expect(bands.count == 1)
        #expect(bands.first?.replaces == [0, 1])
        #expect(bands.first?.reasons == [.split])
    }

    @Test func theCallersLabelLinesAreReread() {
        let line = mono(0, "AZURE_CLIENT_SECRET=kem3nRw7")
        #expect(RereadPlanner.plan(lines: [line], regions: [], imageSize: size, labelLines: [0]).first?.reasons == [.label])
    }

    @Test func anUnreadRegionIsRereadAndReplacesNothing() {
        let read = mono(0, "\"service\": \"billing-api\",", y: 0)
        let skipped = TextRegion(rect: CGRect(x: 100, y: 40, width: 600, height: 20))
        let bands = RereadPlanner.plan(lines: [read], regions: [TextRegion(rect: read.rect), skipped], imageSize: size, labelLines: [])
        #expect(bands.count == 1)
        #expect(bands.first?.reasons == [.unread])
        #expect(bands.first?.replaces == [])
        #expect(bands.first?.core == skipped.rect)
    }

    @Test func aNarrowUnreadRegionIsIgnored() {
        let speck = TextRegion(rect: CGRect(x: 100, y: 40, width: 30, height: 20))   // shorter than any secret format
        #expect(RereadPlanner.plan(lines: [], regions: [speck], imageSize: size, labelLines: []).isEmpty)
    }

    @Test func tilesCoverTheBandFlushAtTheEnd() {
        let tiles = RereadPlanner.tiles(across: CGRect(x: 0, y: 0, width: 1000, height: 30), width: 400, overlap: 100)
        #expect(tiles.map(\.minX) == [0, 300, 600])
        #expect(tiles.last?.maxX == 1000)
        #expect(RereadPlanner.tiles(across: CGRect(x: 0, y: 0, width: 450, height: 30), width: 400, overlap: 100).count == 1)
    }
}

@Suite("Re-read sheet (one Vision request for every strip)")
struct RereadSheetTests {
    @Test func stripsStackWithGapsAndSplitIntoSheetsAtTheLimit() {
        let strips = (0..<5).map { RereadStrip(band: $0, tile: CGRect(x: 0, y: CGFloat($0) * 50, width: 300, height: 30), scale: 2) }
        let one = RereadSheet.layout(strips, maxSide: 4096)
        #expect(one.count == 1)
        let slots = one[0].slots
        #expect(slots.map(\.strip) == [0, 1, 2, 3, 4])
        for (a, b) in zip(slots, slots.dropFirst()) { #expect(b.rect.minY - a.rect.maxY >= 30) }   // half a strip apart
        #expect(slots[0].rect.size == CGSize(width: 600, height: 60))
        #expect(RereadSheet.layout(strips, maxSide: 300).count > 1)
    }

    @Test func observationsMapBackToTheirStripAtFullResolution() throws {
        let strips = [RereadStrip(band: 0, tile: CGRect(x: 1000, y: 200, width: 300, height: 30), scale: 2),
                      RereadStrip(band: 1, tile: CGRect(x: 50, y: 400, width: 300, height: 30), scale: 2)]
        let layout = try #require(RereadSheet.layout(strips, maxSide: 4096).first)
        let second = layout.slots[1].rect
        let observation = OCRLine(index: 0, text: "abc", rect: CGRect(x: second.minX + 20, y: second.minY + 10, width: 60, height: 40),
                                  candidate: CharacterBoxes(boxes: [CGRect(x: second.minX + 20, y: second.minY + 10, width: 20, height: 40),
                                                                    CGRect(x: second.minX + 40, y: second.minY + 10, width: 20, height: 40),
                                                                    CGRect(x: second.minX + 60, y: second.minY + 10, width: 20, height: 40)]))
        let mapped = RereadSheet.mapBack([observation], layout: layout, strips: strips)
        #expect(mapped[0] == nil)
        let line = try #require(mapped[1]?.first)
        #expect(line.rect == CGRect(x: 60, y: 405, width: 30, height: 20))
        #expect(line.candidate?.boundingBox(forUTF16Range: NSRange(location: 1, length: 1)) == CGRect(x: 70, y: 405, width: 10, height: 20))
    }
}

@Suite("Tile stitching")
struct TileStitcherTests {
    func run(_ text: String, x: CGFloat) -> TileStitcher.Run {
        TileStitcher.run(of: [mono(0, text, x: x)])
    }

    @Test func overlappingTilesSeamOnTheirCommonRun() {
        // Tiles [0, 400) and [300, 700) over "0123456789…" at 10 px: the overlap holds ten identical characters.
        let full = String(repeating: "Ab3dE7gH9k", count: 7)                  // 70 characters
        let left = run(String(full.prefix(40)), x: 0)
        let right = run(String(full.dropFirst(30)), x: 300)
        let stitched = TileStitcher.stitch([left, right], tiles: [CGRect(x: 0, y: 0, width: 400, height: 20), CGRect(x: 300, y: 0, width: 400, height: 20)], advance: 10)
        #expect(stitched.text == full)
        #expect(stitched.boxes.count == 70)
        #expect(stitched.boxes[69].maxX == 700)
    }

    @Test func aMisreadEdgeGlyphIsDroppedAtTheSeam() {
        let full = String(repeating: "Ab3dE7gH9k", count: 7)
        let left = run(String(full.prefix(39)) + "#", x: 0)                  // the cut glyph at the tile edge, misread
        let right = run("%" + String(full.dropFirst(31)), x: 300)
        let stitched = TileStitcher.stitch([left, right], tiles: [CGRect(x: 0, y: 0, width: 400, height: 20), CGRect(x: 300, y: 0, width: 400, height: 20)], advance: 10)
        #expect(stitched.text == full)
    }

    @Test func withNoCommonRunTheSeamIsTheMiddleOfTheOverlap() {
        let left = run("aaaaaaaaaaBBBB", x: 0)                                // x 0…140
        let right = run("ccccdddddddddd", x: 100)                             // x 100…240
        let stitched = TileStitcher.stitch([left, right], tiles: [CGRect(x: 0, y: 0, width: 140, height: 20), CGRect(x: 100, y: 0, width: 140, height: 20)], advance: 10)
        #expect(stitched.text == "aaaaaaaaaaBB" + "ccdddddddddd")             // each tile keeps its side of x = 120
    }

    /// Fail-open #22: three tiles, the middle one with no reading. The stitch joins tiles 1 and 3, so its text runs on
    /// across ink nobody read; it must say which tile it had no reading for, so the band is reported as not read.
    @Test func aMissingMiddleTileIsReportedNotStitchedOverQuietly() {
        let full = String(repeating: "Ab3dE7gH9k", count: 10)                 // 100 characters, x 0…1000
        let tiles = [CGRect(x: 0, y: 0, width: 400, height: 20), CGRect(x: 300, y: 0, width: 400, height: 20),
                     CGRect(x: 600, y: 0, width: 400, height: 20)]
        let first = run(String(full.prefix(40)), x: 0), last = run(String(full.dropFirst(60)), x: 600)
        let stitched = TileStitcher.stitch([first, TileStitcher.Run(units: [], boxes: []), last], tiles: tiles, advance: 10)
        #expect(stitched.unreadTiles == [1])
        #expect(stitched.text.utf16.count < full.utf16.count)                  // the gap's glyphs are not in the text
        let whole = TileStitcher.stitch([first, run(String(full.dropFirst(30).prefix(40)), x: 300), last], tiles: tiles, advance: 10)
        #expect(whole.unreadTiles.isEmpty && whole.text == full)
        let none = TileStitcher.stitch([TileStitcher.Run(units: [], boxes: []), TileStitcher.Run(units: [], boxes: [])],
                                       tiles: Array(tiles.prefix(2)), advance: 10)
        #expect(none.unreadTiles == [0, 1] && none.units.isEmpty)
    }

    @Test func longestCommonRunFindsTheLongest() throws {
        let a = Array("xxABCDEyy".utf16), b = Array("zABCDEw".utf16)
        let seam = try #require(TileStitcher.longestCommonRun(a, b))
        #expect(seam.left == 2 && seam.right == 1 && seam.length == 5)
        #expect(TileStitcher.longestCommonRun(Array("ab".utf16), Array("cd".utf16)) == nil)
    }

    @Test func theStitchedLineAnswersEachCharactersOwnBox() throws {
        let line = try #require(TileStitcher.line(run("abc def", x: 100), index: 7))
        #expect(line.index == 7)
        #expect(line.candidate?.isCharacterExact == true)
        #expect(line.candidate?.boundingBox(forUTF16Range: NSRange(location: 4, length: 3)) == CGRect(x: 140, y: 0, width: 30, height: 20))
    }
}

@Suite("Cover geometry on the glyph grid")
struct GlyphGridTests {
    /// One ink box per non-space character of `text` on a 10 px grid from x = 100 (letters span the row's middle).
    func ink(_ text: String, thin: Set<Character> = [",", ".", ":", "\""]) -> [CGRect] {
        text.enumerated().compactMap { i, c in
            if c == " " { return nil }
            let x = 100 + CGFloat(i) * 10
            if c == "\"" { return CGRect(x: x + 3, y: 2, width: 5, height: 6) }          // above the middle
            if c == "," { return CGRect(x: x + 4, y: 14, width: 2, height: 6) }          // below the middle
            if thin.contains(c) { return CGRect(x: x + 4, y: 6, width: 2, height: 10) }
            return CGRect(x: x + 1, y: 4, width: 8, height: 12)
        }
    }

    @Test func aMonospaceRowFitsAndAProportionalOneDoesNot() throws {
        let grid = try #require(GlyphGrid.fit(ink("abcdefghijklmnop"), lineHeight: 20))
        #expect(abs(grid.advance - 10) < 0.01)
        #expect(abs(grid.left(of: 0) - 100) < 0.01)
        var x: CGFloat = 0
        let proportional = (0..<16).map { i -> CGRect in defer { x += CGFloat(4 + (i * 7) % 11) }; return CGRect(x: x, y: 0, width: 3, height: 12) }
        #expect(GlyphGrid.fit(proportional, lineHeight: 20) == nil)
    }

    @Test func aDriftedEstimateSnapsToTheTokensCells() throws {
        let text = #""db": "postgres://app:Secr3tPassw0rd@db.example:5432/app","#
        let line = OCRLine(index: 0, text: text, rect: CGRect(x: 100, y: 0, width: CGFloat(text.utf16.count) * 10, height: 20), glyphBoxes: ink(text))
        let grid = try #require(GlyphGrid.fit(line.glyphBoxes, lineHeight: 20))
        let secret = (text as NSString).range(of: "Secr3tPassw0rd")
        let word = BoxMapper.widenToWord(secret, in: text)
        for drift in -2...2 {                                                       // estimate off by up to two glyphs
            let cells = grid.cover(Array(text.utf16), token: secret, word: word, near: secret.location + drift)
            #expect(cells == secret.location...(NSMaxRange(secret) - 1), "drift \(drift)")
        }
    }

    @Test func aGlyphTheReadDroppedInsideTheTokenStaysCovered() throws {
        let truth = #""k": "rubygems_0a1b2c3d4e5f6a7bff","#
        let read = #""k": "rubygems_0a1b2c3d4e5f6a7bf"#                                // one `f`, the `"` and the `,` dropped
        let grid = try #require(GlyphGrid.fit(ink(truth), lineHeight: 20))
        let token = (read as NSString).range(of: "rubygems_0a1b2c3d4e5f6a7bf")
        let cells = grid.cover(Array(read.utf16), token: token, word: BoxMapper.widenToWord(token, in: read), near: token.location)
        let truthToken = (truth as NSString).range(of: "rubygems_0a1b2c3d4e5f6a7bff")
        #expect(cells == truthToken.location...(NSMaxRange(truthToken) - 1))      // every glyph, not the `",`
    }

    /// Vision-style fullwidth output (measured 2026-10-27, Menlo 13 on a dark terminal): `(212) 555-0199` read as
    /// `（212）555-0199`, the closing parenthesis standing for `) `: 13 characters on 14 cells, the word's ink in two runs
    /// one empty cell apart. The cover takes every glyph, both parentheses included.
    @Test func aSpaceTheReadDroppedInsideAWordStaysInsideItsCover() throws {
        let truth = "(212) 555-0199"
        let read = "（212）555-0199"
        let glyphs = ink(truth)
        let grid = try #require(GlyphGrid.fit(glyphs, lineHeight: 20))
        let token = NSRange(location: 0, length: read.utf16.count)
        for near in -1...1 {
            let cells = grid.cover(Array(read.utf16), token: token, word: BoxMapper.widenToWord(token, in: read), near: near)
            #expect(cells == 0...13, "near \(near)")
        }
        let line = OCRLine(index: 0, text: read, rect: CGRect(x: 102, y: 0, width: 136, height: 20), glyphBoxes: glyphs)
        let cover = BoxMapper.rect(forUTF16Range: token, in: line)
        #expect(cover.minX <= 101 && cover.maxX >= 239)                             // the `(` at 101…109, the last `9` at 231…239
        // Two words the read keeps apart are still two runs: the space is not bridged when the word fits its own run.
        let pair = "(212) 555-0199"
        let second = (pair as NSString).range(of: "555-0199")
        let cells = grid.cover(Array(pair.utf16), token: second, word: BoxMapper.widenToWord(second, in: pair), near: second.location)
        #expect(cells == 6...13)
    }

    @Test func wideningStopsAfterASchemeSeparatorAndAtNonASCIINoise() {
        let dsn = "https://3a35eb5e1e87e9fd@o1.ingest.sentry.io/1"
        let key = (dsn as NSString).range(of: "3a35eb5e1e87e9fd")
        #expect(BoxMapper.widenToToken(key, in: dsn) == key)
        let ip = "\"2001:db8::1¿‚"
        let address = NSRange(location: 1, length: 11)
        #expect(BoxMapper.widenToToken(address, in: ip) == address)
    }

    @Test func aWholeLineCoverReachesTheInkVisionDropped() {
        let text = "-----BEGIN EXAMPLE ARMOR BLOCK-"                                  // 31 cells, x 100…410
        let line = OCRLine(index: 0, text: "-BEGIN EXAMPLE ARMOR BLO", rect: CGRect(x: 140, y: 0, width: 250, height: 20), glyphBoxes: ink(text))
        let cover = BoxMapper.wholeLineRect(line)
        #expect(cover.minX <= 101 && cover.maxX >= 409)
    }
}

@Suite("Ink cells from pixels")
struct InkCellsTests {
    @Test func runsAreMaximalInkedColumnRuns() {
        let columns: [ClosedRange<Int>?] = [nil, 1...3, 2...4, nil, nil, 0...1, nil]
        #expect(InkCells.runs(columns) == [1..<3, 5..<6])
    }

    @Test func eachCellGetsTheBoundingBoxOfItsInk() {
        var columns = [ClosedRange<Int>?](repeating: nil, count: 40)
        for x in 2...7 { columns[x] = 4...15 }      // a letter in cell 0
        for x in 13...15 { columns[x] = 2...6 }     // a quote in cell 1
        let grid = GlyphGrid(origin: 5, advance: 10)
        let boxes = InkCells.cells(columns: columns, originX: 100, originY: 50, grid: grid)
        #expect(boxes == [CGRect(x: 102, y: 54, width: 6, height: 12), CGRect(x: 113, y: 52, width: 3, height: 5)])
    }

    @Test func measuredOnARenderedRowTheGridMatchesTheDrawing() throws {
        // Draw 20 black 8×12 bars on a 10 px grid on white, and measure them back.
        let width = 300, height = 30
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for i in 0..<20 { ctx.fill(CGRect(x: 51 + i * 10, y: 9, width: 8, height: 12)) }
        let image = ctx.makeImage()!
        let line = OCRLine(index: 0, text: String(repeating: "a", count: 20), rect: CGRect(x: 50, y: 5, width: 200, height: 20))
        let boxes = InkCells.measure(image, line: line)
        #expect(boxes.count == 20)
        let grid = try #require(GlyphGrid.fit(boxes, lineHeight: 20))
        #expect(abs(grid.advance - 10) < 0.05)
        #expect(abs(grid.left(of: grid.cell(nearest: 55)) - 50) < 0.6)
    }
}

@Suite("Recall reader")
struct RecallReaderTests {
    @Test func aRecognizerThatDoesNotReadPixelsIsNeverRereadAndTheLabelTriggerIsNotAsked() async throws {
        let long = mono(0, String(repeating: "Ab3dE", count: 60))
        let reading = try await RecallReader.read(blankImage(width: 4000, height: 100), options: OCROptions(),
                                                  recognizer: StubTextRecognizer(lines: [long])) { _ in
            Issue.record("the label trigger runs only when a re-read is possible")
            return []
        }
        #expect(reading.lines.count == 1)
        #expect(reading.rereads.isEmpty)
        #expect(reading.rereadLines.map(\.text) == [long.text])
    }

    @Test func rereadLinesPutEachRereadInPlaceOfWhatItReplaces() {
        let a = mono(0, "first"), b = mono(1, "secon"), c = mono(2, "third")
        let reread = Reread(replaces: [1], line: mono(9, "second"), reasons: [.split])
        let reading = RecallReading(lines: [a, b, c], rereads: [reread])
        #expect(reading.rereadLines.map(\.text) == ["first", "third", "second"])
        #expect(reading.rereadLines.map(\.index) == [0, 1, 2])
    }
}
