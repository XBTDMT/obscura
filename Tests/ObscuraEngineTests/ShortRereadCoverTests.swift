// G-22 regression (knowledge/redman/LEDGER.md, "cloud.aws.sessiontoken fixture fails cover on some runs"): under ANE
// load one re-read sheet came back with only a short duplicate fragment for a middle strip of a 322-glyph line; the
// strip looked read, the stitch joined across the glyphs nobody read, and the cover stopped 86 glyphs short. Here the
// same failure is scripted: the middle strip answers a 23-unit fragment on every request. The cover must still reach
// the end of the line's ink, and never the key name. Every value is made up.
import CoreGraphics
import Foundation
import ObscuraDetect
@testable import ObscuraOCR
import Testing
@testable import ObscuraEngine

@Suite("Short re-read cover (G-22)")
struct ShortRereadCoverTests {
    let fixture = LongLineFixture()

    func detect(_ recognizer: ShortSheetRecognizer) async throws -> (RecallReading, ImageDetection) {
        let reading = try await RecallReader.read(fixture.image, options: OCROptions(), recognizer: recognizer) { _ in [] }
        let scanner = ObscuraDetect.Scanner(catalogue: try Catalogue.resolved(state: ["cloud.aws.sessiontoken": true]))
        let detection = RecallPipeline.detect(reading, image: fixture.image, scanner: scanner,
                                              imageSize: CGSize(width: fixture.image.width, height: fixture.image.height), titles: [:])
        return (reading, detection)
    }

    /// Token glyphs whose ink no area covers completely.
    func visibleTokenGlyphs(_ areas: [DetectedArea]) -> [Int] {
        fixture.tokenRange.filter { i in !areas.contains { $0.rect.contains(LongLineFixture.ink(i)) } }
    }

    /// Key-name glyphs (`aws_session_token`) any area touches.
    func touchedLabelGlyphs(_ areas: [DetectedArea]) -> [Int] {
        (0..<17).filter { i in areas.contains { $0.rect.intersects(LongLineFixture.ink(i)) } }
    }

    @Test func aStripThatReturnsOnlyAFragmentOnEveryRequestStillLeavesNoTokenGlyphVisible() async throws {
        let strips = fixture.strips()
        try #require(strips.count == 4)
        let middle = 1
        let recognizer = ShortSheetRecognizer(fixture: fixture) { call in
            // Attempt 0: every strip; then only the short one, at 1.25× and at 0.8× (never below 1×).
            switch call {
            case 0: return strips.enumerated().map { ($1, $0 == middle ? 23 : nil) }
            case 1: return [(RereadStrip(band: 0, tile: strips[middle].tile, scale: max(1, strips[middle].scale * 1.25)), 23)]
            default: return [(RereadStrip(band: 0, tile: strips[middle].tile, scale: max(1, strips[middle].scale * 0.8)), 23)]
            }
        }
        let (_, detection) = try await detect(recognizer)
        #expect(detection.areas.contains { $0.detectorIDs.contains("cloud.aws.sessiontoken") })
        let visible = visibleTokenGlyphs(detection.areas)
        #expect(visible.isEmpty, "\(visible.count) token glyph(s) visible, first at unit \(visible.first ?? -1)")
        #expect(touchedLabelGlyphs(detection.areas).isEmpty)
    }
}
