// Security scan 2026-10-28, F13: a re-read band's height comes from the picture's text, and the sheet layout admitted a
// first strip whatever its size, so two words in a 9,000 px font became a 506 MP sheet (2 GB drawn) handed to Vision
// at full size. Scaled here with a small `sheetMaxSide`; every image is blank and tiny, and the recognizer only records
// the sizes it is asked to read.
import CoreGraphics
import Foundation
import Testing
@testable import ObscuraOCR

/// Pass 1 reads `lines`; every later request (sheets, last attempts) is recorded by its pixel count and read as nothing.
actor SizeLog {
    private(set) var areas: [Int] = []
    func record(_ area: Int) { areas.append(area) }
}

struct SizeRecordingRecognizer: TextRecognizer {
    let lines: [OCRLine]
    let log = SizeLog()
    var rereadsPixels: Bool { true }
    func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading { OCRReading(lines: lines) }
    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        await log.record(image.width * image.height)
        return []
    }
}

@Suite("A re-read sheet never grows past its ceiling (security F13)")
struct OversizeSheetTests {
    /// The scan's strip: a 4,080 px tile of 14,000 px tall text at 1×. The old layout put it on a sheet of its own,
    /// 18,080 × 28,000 px (506 MP); now it is on no sheet.
    @Test func aStripTallerThanASheetIsOnNoSheet() {
        let tall = RereadStrip(band: 0, tile: CGRect(x: 0, y: 0, width: 4080, height: 14000), scale: 1)
        #expect(!RereadSheet.fits(tall, maxSide: 4096))
        #expect(RereadSheet.layout([tall], maxSide: 4096).isEmpty)
    }

    /// Strips that fit keep their sheets; the one that does not is simply missing, so the caller can mark it unread. And
    /// stacking never builds a sheet past the area: many wide strips split over several sheets.
    @Test func onlyTheOversizeStripIsLeftOut() {
        let small = { (band: Int) in RereadStrip(band: band, tile: CGRect(x: 0, y: CGFloat(band) * 40, width: 600, height: 30), scale: 2) }
        let tall = RereadStrip(band: 1, tile: CGRect(x: 0, y: 100, width: 600, height: 3000), scale: 1)
        let sheets = RereadSheet.layout([small(0), tall, small(2)], maxSide: 4096)
        #expect(sheets.flatMap { $0.slots.map(\.strip) } == [0, 2])
        let wide = (0..<6).map { RereadStrip(band: $0, tile: CGRect(x: 0, y: CGFloat($0) * 700, width: 12000, height: 600), scale: 1) }
        let stacked = RereadSheet.layout(wide, maxSide: 4096)
        #expect(stacked.flatMap { $0.slots.map(\.strip) } == Array(0..<6))
        #expect(stacked.count == 3, "two per sheet: a third would pass the area, though not the height")
        for sheet in stacked { #expect(sheet.size.width * sheet.size.height <= RereadSheet.maxPixels(maxSide: 4096)) }
        for sheet in sheets {
            #expect(sheet.size.height <= 4096)
            #expect(sheet.size.width * sheet.size.height <= RereadSheet.maxPixels(maxSide: 4096))
        }
    }

    /// The planner's widest strip (a band left whole at 1.15 × the tile width, on the 1.25 × retry) still fits, so the
    /// area rule never refuses a real band; a strip far wider than any tile the planner makes, within the height, does not.
    @Test func thePlannersWidestStripFits() {
        let tuning = RecallTuning()
        let tile = 1.15 * (CGFloat(tuning.sheetMaxSide) - 16)
        let widest = RereadStrip(band: 0, tile: CGRect(x: 0, y: 0, width: tile, height: 120), scale: 1.25)
        #expect(RereadSheet.fits(widest, maxSide: tuning.sheetMaxSide))
        let wider = RereadStrip(band: 0, tile: CGRect(x: 0, y: 0, width: 20000, height: 1000), scale: 1)
        #expect(!RereadSheet.fits(wider, maxSide: tuning.sheetMaxSide))
        let empty = RereadStrip(band: 0, tile: CGRect(x: 0, y: 0, width: 0, height: 40), scale: 1)
        #expect(!RereadSheet.fits(empty, maxSide: tuning.sheetMaxSide))
    }

    /// End to end, scaled: two words 150 px tall that nearly touch (a `split` re-read) on a 600 × 400 picture, against a
    /// 256 px sheet. The band's strip does not fit at any scale, and its full-width last attempt is larger than a sheet
    /// may be: nothing larger than `sheetMaxPixels` is ever handed to the recognizer, and the band is unread for being
    /// too large, so the picture ends "not checked" (failed, not timed out), never clean. With the old rule (every
    /// strip admitted) the largest request was a 421,120 px sheet, 3.2 × the ceiling (measured 2026-10-28).
    @Test func aBandTooTallForASheetIsUnreadAndNothingLargerIsRead() async throws {
        var tuning = RecallTuning()
        tuning.sheetMaxSide = 256
        let lines = [line(0, "alpha", x: 20, y: 100, w: 100, h: 150), line(1, "beta", x: 125, y: 100, w: 100, h: 150)]
        let recognizer = SizeRecordingRecognizer(lines: lines)
        let reading = try await RecallReader.read(blankImage(width: 600, height: 400), options: OCROptions(), recognizer: recognizer,
                                                  tuning: tuning) { _ in [] }
        #expect(reading.stats.bands == 1)
        #expect(reading.stats.oversizeStrips >= 1)
        let areas = await recognizer.log.areas
        #expect(areas.allSatisfy { $0 <= tuning.sheetMaxPixels }, "largest request \(areas.max() ?? 0) px")
        #expect(!reading.completeness.isComplete)
        #expect(reading.completeness.incomplete.first?.gaps == [.oversize])
        #expect(reading.completeness.timedOut == false)
    }
}
