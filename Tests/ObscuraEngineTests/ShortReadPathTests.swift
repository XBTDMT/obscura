// G-22: the paths around a short re-read: a strip read again and read whole (no fallback), a full read never retried,
// a strip still short after the bounded retries (marked, covered conservatively), and the rule for a short line with no
// finding (labelled value or vendor prefix, covered to the ink's end). Every value is made up.
import CoreGraphics
import Foundation
import ObscuraDetect
@testable import ObscuraOCR
import Testing
@testable import ObscuraEngine

@Suite("Short re-read: retry, no false fallback, label-only lines (G-22)")
struct ShortReadPathTests {
    let fixture = LongLineFixture()

    func run(_ recognizer: ShortSheetRecognizer) async throws -> (RecallReading, ImageDetection) {
        try await ShortRereadCoverTests().detect(recognizer)
    }

    @Test func aFragmentStripIsReadAgainAndTheRetryReadsTheWholeLineWithNoFallback() async throws {
        let strips = fixture.strips()
        try #require(strips.count == 4)
        let recognizer = ShortSheetRecognizer(fixture: fixture) { call in
            switch call {
            case 0: return strips.enumerated().map { ($1, $0 == 1 ? 23 : nil) }
            default: return [(RereadStrip(band: 0, tile: strips[1].tile, scale: max(1, strips[1].scale * 1.25)), nil)]
            }
        }
        let (reading, detection) = try await run(recognizer)
        #expect(await recognizer.calls.count == 2)
        #expect(reading.stats.retriedStrips == 1 && reading.stats.shortStrips == 1)
        #expect(reading.stats.shortBands == 0)
        #expect(reading.rereads.map(\.line.text) == [fixture.text])
        #expect(reading.rereads.allSatisfy { $0.line.shortRead == nil } && reading.lines.allSatisfy { $0.shortRead == nil })
        #expect(detection.conservativeAreas == 0)
        #expect(ShortRereadCoverTests().visibleTokenGlyphs(detection.areas).isEmpty)
    }

    @Test func aFullReadIsNeverRetriedAndNeverFallsBack() async throws {
        let strips = fixture.strips()
        let recognizer = ShortSheetRecognizer(fixture: fixture) { call in call == 0 ? strips.map { ($0, nil) } : [] }
        let (reading, detection) = try await run(recognizer)
        #expect(await recognizer.calls.count == 1)
        #expect(reading.stats.retriedStrips == 0 && reading.stats.shortStrips == 0 && reading.stats.shortBands == 0)
        let band = try #require(reading.stats.bandCounts.first)
        #expect(band.units == band.ink && band.uncovered == 0)
        #expect(reading.rereads.map(\.line.text) == [fixture.text])
        #expect(detection.conservativeAreas == 0 && detection.shortReads == 0)
        #expect(ShortRereadCoverTests().visibleTokenGlyphs(detection.areas).isEmpty)
    }

    @Test func aStripStillShortAfterTheBoundedRetriesMarksTheBandAndCoversConservatively() async throws {
        let strips = fixture.strips()
        let recognizer = ShortSheetRecognizer(fixture: fixture) { call in
            switch call {
            case 0: return strips.enumerated().map { ($1, $0 == 1 ? 23 : nil) }
            case 1: return [(RereadStrip(band: 0, tile: strips[1].tile, scale: max(1, strips[1].scale * 1.25)), 23)]
            default: return [(RereadStrip(band: 0, tile: strips[1].tile, scale: max(1, strips[1].scale * 0.8)), 23)]
            }
        }
        let (reading, detection) = try await run(recognizer)
        // One sheet, then one retry per `retryScales` entry: bounded.
        #expect(await recognizer.calls.count == 1 + RecallTuning().retryScales.count)
        #expect(reading.stats.shortBands == 1)
        let short = try #require(reading.rereads.first?.line.shortRead)
        #expect(short.count.ink == fixture.count - 2 && short.count.units < short.count.ink)
        #expect(reading.lines.allSatisfy { $0.shortRead != nil })
        #expect(detection.shortReads == 1 && detection.conservativeAreas >= 1)
        // The conservative cover runs to the end of the ink and starts at the value, not over the key name.
        let cover = try #require(detection.areas.first { $0.conservative && $0.detectorIDs.contains("cloud.aws.sessiontoken") })
        #expect(cover.rect.maxX >= LongLineFixture.ink(fixture.count - 1).maxX)
        #expect(cover.rect.minX > LongLineFixture.ink(16).maxX)
    }

    /// A line marked short (G-22 rule, part 2) whose ink runs on to `inkCells` cells; placed without an image, so the
    /// geometry is the read's own.
    func shortLine(_ text: String, inkCells: Int) -> OCRLine {
        let units = Array(text.utf16)
        let ink = (0..<inkCells).filter { $0 >= units.count || units[$0] != 0x20 }.map(LongLineFixture.ink)
        let count = ReadCount(units: units.count, ink: inkCells, uncovered: inkCells - units.count, isGrid: true)
        return OCRLine(index: 0, text: text, rect: CGRect(x: LongLineFixture.x0, y: LongLineFixture.y0, width: CGFloat(units.count) * 10, height: 20),
                       candidate: CharacterBoxes(boxes: units.indices.map(LongLineFixture.cell)),
                       shortRead: ShortRead(band: 0, count: count, ink: ink, advance: 10))
    }

    func detectLines(_ lines: [OCRLine], enabled: [String: Bool]) throws -> ImageDetection {
        let scanner = ObscuraDetect.Scanner(catalogue: try Catalogue.resolved(state: enabled))
        return RecallPipeline.detect(RecallReading(lines: lines), scanner: scanner, imageSize: CGSize(width: 2000, height: 60), titles: [:])
    }

    @Test func aShortLineWhoseValueNoDetectorAcceptsIsCoveredFromTheLabelledValueToTheInkEnd() throws {
        // `aaaaaaaa` fails config.env.secret's entropy check, so no detector reports it; the read lost the rest.
        let detection = try detectLines([shortLine("SESSION_SECRET=aaaaaaaa", inkCells: 60)], enabled: [:])
        #expect(detection.findingCount == 1)
        let area = try #require(detection.areas.first)
        #expect(detection.areas.count == 1 && area.conservative && area.detectorIDs == ["config.env.secret"])
        #expect(area.rect.minX > LongLineFixture.ink(13).maxX)          // the key name stays visible (the `=` is the framing edge)
        #expect(area.rect.maxX >= LongLineFixture.ink(59).maxX)         // the ink the read lost is covered
    }

    @Test func aShortLineWithAVendorPrefixIsCoveredFromThePrefixToTheInkEnd() throws {
        let detection = try detectLines([shortLine("token is hf_Ab3dE", inkCells: 50)], enabled: ["ai.huggingface.token": true])
        let area = try #require(detection.areas.first)
        #expect(detection.areas.count == 1 && area.conservative && area.detectorIDs == ["ai.huggingface.token"])
        #expect(area.rect.minX > LongLineFixture.ink(7).maxX && area.rect.maxX >= LongLineFixture.ink(49).maxX)
    }

    @Test func aShortLineWithNoLabelOrPrefixAndAnUnmarkedLabelLineAreNotCovered() throws {
        let plain = shortLine("nothing to see on this line", inkCells: 50)
        #expect(try detectLines([plain], enabled: ["ai.huggingface.token": true]).areas.isEmpty)
        var unmarked = shortLine("SESSION_SECRET=aaaaaaaa", inkCells: 23)
        unmarked.shortRead = nil
        #expect(try detectLines([unmarked], enabled: [:]).areas.isEmpty)
    }
}
