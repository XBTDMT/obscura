// How the re-read pass's covers merge with pass 1's (G-12, RecallPipeline.merge). Regression for the 2026-10-27 defect
// in knowledge/redman/LEDGER.md: six secrets on six tight consecutive lines came back as ONE cover over all six lines,
// key names included, because a re-read area absorbed every area it touched and kept growing. Every value is made up.
import CoreGraphics
import Foundation
import ObscuraDetect
@testable import ObscuraOCR
import Testing
@testable import ObscuraEngine

private func area(_ rect: CGRect, _ ids: [String], line: Int = 0) -> DetectedArea {
    DetectedArea(rect: rect, textHeight: rect.height, lineIndex: line, detectorIDs: ids, category: "tokens", label: "Secret",
                 id: UUID())
}

@Suite("Re-read cover merge")
struct RecallMergeTests {
    /// Six rows 26 px apart whose 30 px boxes overlap their neighbours by 4 px (the repro's geometry), x ranges overlapping.
    let rows: [CGRect] = (0..<6).map { CGRect(x: 250 - CGFloat($0 % 2) * 60, y: 113 + 26 * CGFloat($0), width: 400, height: 30) }

    @Test func areasOnNeighbouringRowsNeverMergeEvenWhenTheyTouch() {
        let first = rows.enumerated().map { area($1, ["d\($0)"], line: $0) }
        let second = rows.enumerated().map { area($1, ["d\($0)"], line: $0) }          // the second scan's twins
        let merged = RecallPipeline.merge(first, second)
        #expect(merged.count == 6)
        #expect(merged.map(\.rect) == rows)
        #expect(merged.map(\.detectorIDs) == (0..<6).map { ["d\($0)"] })
    }

    @Test func aRereadAreaOverlappingTheRowAboveMergesOnlyWithItsOwnRow() {
        let first = rows.enumerated().map { area($1, ["d\($0)"], line: $0) }
        // A re-read of row 2, one pixel taller than pass 1's box and reaching 5 px into row 1's.
        let reread = area(CGRect(x: rows[2].minX + 10, y: rows[2].minY - 1, width: 300, height: 31), ["d2", "extra"], line: 2)
        let merged = RecallPipeline.merge(first, [reread])
        #expect(merged.count == 6)
        #expect(merged.map(\.rect) == rows)
        #expect(merged[2].detectorIDs == ["d2", "extra"])
        #expect(merged[1].detectorIDs == ["d1"] && merged[3].detectorIDs == ["d3"])
    }

    @Test func aSameRowDuplicateDedupesToTheFirstPassBoxWithoutGrowing() {
        let pass1 = CGRect(x: 100, y: 50, width: 200, height: 30)
        let merged = RecallPipeline.merge([area(pass1, ["a"])], [area(CGRect(x: 110, y: 48, width: 150, height: 34), ["a", "b"])])
        #expect(merged.count == 1)
        #expect(merged.first?.rect == pass1)
        #expect(merged.first?.textHeight == 30)
        #expect(merged.first?.detectorIDs == ["a", "b"])
    }

    @Test func aRereadThatReadsFurtherExtendsTheCoverAlongItsRowOnly() {
        // Pass 1 stopped reading a long value early; the re-read reads all of it.
        let merged = RecallPipeline.merge([area(CGRect(x: 100, y: 50, width: 120, height: 30), ["a"])],
                                          [area(CGRect(x: 100, y: 49, width: 300, height: 32), ["a"])])
        #expect(merged.count == 1)
        #expect(merged.first?.rect == CGRect(x: 100, y: 50, width: 300, height: 30))
    }

    @Test func twoFindingsOnOneRowThatDoNotOverlapStayTwo() {
        let merged = RecallPipeline.merge([area(CGRect(x: 100, y: 50, width: 100, height: 30), ["a"])],
                                          [area(CGRect(x: 300, y: 50, width: 100, height: 30), ["b"])])
        #expect(merged.count == 2)
    }

    @Test func aRereadOfTextPassOneNeverReadIsKept() {
        let merged = RecallPipeline.merge([area(rows[0], ["a"])], [area(CGRect(x: 100, y: 400, width: 200, height: 30), ["b"])])
        #expect(merged.map(\.detectorIDs) == [["a"], ["b"]])
    }
}

@Suite("Multi-line covers through the recall pipeline")
struct RecallPipelineMultiLineTests {
    /// The repro's text block: label=value on six consecutive lines (made-up values from Tests/Fixtures/text).
    static let lines: [(text: String, detector: String)] = [
        ("STRIPE_SECRET_KEY=sk_live_gHBJ59jWkyqhEGdgw5UhJjnc", "payments.stripe.secretkey"),
        ("ANTHROPIC_API_KEY=sk-ant-api03-OdR-zLBztqrYi_rvGbv_a_Qx0nby3pkIrvS2pn9v7rZHTaTc8eH2yOynBcI5AA", "ai.anthropic.apikey"),
        ("GITHUB_TOKEN=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", "scm.github.token"),
        ("DATABASE_URL=postgres://app:UJ3S7t8XofbcbG3y@db.example.internal:5432/app", "databases.url.credentials"),
        ("AWS_ACCESS_KEY_ID=AKIABOW3UJG66TEOFP2G", "cloud.aws.accesskeyid"),
        ("CARD_NUMBER=4111 1111 1111 1111", "personal.card.pan"),
    ]
    static let advance: CGFloat = 13.4, pitch: CGFloat = 26, height: CGFloat = 30, left: CGFloat = 12

    /// Line `i` as Vision would hand it over: monospace character boxes, a 30 px box on a 26 px pitch (4 px overlap).
    static func line(_ i: Int, dy: CGFloat = 0, dh: CGFloat = 0) -> OCRLine {
        let text = lines[i].text
        let y = 113 + pitch * CGFloat(i) + dy
        let boxes = (0..<text.utf16.count).map { CGRect(x: left + CGFloat($0) * advance, y: y, width: advance, height: height + dh) }
        return OCRLine(index: i, text: text, rect: CGRect(x: left, y: y, width: CGFloat(boxes.count) * advance, height: height + dh),
                       candidate: CharacterBoxes(boxes: boxes))
    }

    @Test func aRereadOnOneOfSixTightLinesLeavesOneCoverPerLineOffItsKeyName() throws {
        let scanner = ObscuraDetect.Scanner(catalogue: try Catalogue.resolved())
        let first = (0..<6).map { Self.line($0) }
        // The repro's re-read: the GitHub line read again as one band, a pixel taller than pass 1's box.
        let reading = RecallReading(lines: first, rereads: [Reread(replaces: [2], line: Self.line(2, dy: -1, dh: 1), reasons: [.split])])
        let detection = RecallPipeline.detect(reading, scanner: scanner, imageSize: CGSize(width: 1300, height: 400), titles: [:])

        #expect(detection.areas.count == 6, "areas \(detection.areas.map { "\($0.rect)" })")
        for (i, expected) in Self.lines.enumerated() {
            let row = Self.line(i).rect
            let mine = detection.areas.filter { RecallPipeline.sameRow($0.rect, row) }
            #expect(mine.count == 1, "line \(i): \(mine.count) covers")
            guard let cover = mine.first else { continue }
            #expect(cover.detectorIDs.contains(expected.detector), "line \(i): \(cover.detectorIDs)")
            #expect(cover.rect.height <= 1.6 * Self.height, "line \(i): cover \(cover.rect.height) px tall")
            let equals = CGFloat(expected.text.utf16.firstIndex(of: 0x3D).map { expected.text.utf16.distance(from: expected.text.utf16.startIndex, to: $0) }!)
            #expect(cover.rect.minX >= Self.left + equals * Self.advance, "line \(i): cover starts over the key name")
        }
    }
}
