// The real engine path (Vision pass 1, the G-12 re-reads, merge, placement) on the sample terminal drawn with a dense
// editor's line pitch: one cover per secret line, line-high, never over its key name. Regression for the 2026-10-27
// defect in knowledge/redman/LEDGER.md (six tight lines covered by one box). Every value is made up. Real Vision runs,
// so it is skipped under CI like VisionSmokeTests; logs and messages carry rects and detector ids only.
import CoreGraphics
import CoreText
import Foundation
import ObscuraDetect
import ObscuraEngine
import ObscuraOCR
import ObscuraRender
import Testing
@testable import ObscuraUIKit

@Suite(.serialized) struct SampleTerminalCoverTests {
    /// The repro's six label=value lines (values from SampleData and Tests/Fixtures/text), after a prompt line.
    static let secrets: [(text: String, detector: String)] = [
        (SampleData.envLines[1], "payments.stripe.secretkey"),
        (SampleData.envLines[2], "ai.anthropic.apikey"),
        (SampleData.envLines[3], "scm.github.token"),
        (SampleData.envLines[4], "databases.url.credentials"),
        ("AWS_ACCESS_KEY_ID=AKIABOW3UJG66TEOFP2G", "cloud.aws.accesskeyid"),
        ("CARD_NUMBER=4111 1111 1111 1111", "personal.card.pan"),
    ]
    /// 18 pt on 15 pt Menlo (1.2×): Vision's boxes for neighbouring lines overlap, as in the repro's editor.
    static let pitch: CGFloat = 18

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func sixTightLinesGetSixCoversOffTheirKeyNames() async throws {
        let lines = ["$ cat .env.local"] + Self.secrets.map(\.text)
        let reading = try await check(lines: lines, width: 960)
        // The geometry the defect needs: pass 1's boxes for at least one pair of neighbouring lines overlap vertically.
        let boxes = reading.lines.map(\.rect).sorted { $0.midY < $1.midY }
        #expect(zip(boxes, boxes.dropFirst()).contains { $0.maxY > $1.minY && $0.maxX > $1.minX && $1.maxX > $0.minX },
                "no neighbouring line boxes overlap: the image does not reproduce the tight pitch")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func aRereadLongLineAmongTightLinesKeepsOneCoverPerLine() async throws {
        // The Anthropic line made long enough (≥ 96 units) that G-12 re-reads it, so the two readings are merged.
        var lines = ["$ cat .env.local"] + Self.secrets.map(\.text)
        lines[2] += "   # rotated 2026-10-27 by deploy-bot"
        let reading = try await check(lines: lines, width: 1240)
        #expect(!reading.rereads.isEmpty, "no re-read ran: the variant does not exercise the merge")
    }

    /// Draws `lines`, runs the engine's recall pipeline on them and checks every secret line's cover. Returns the reading.
    func check(lines: [String], width: Int) async throws -> RecallReading {
        let layout = SampleData.TerminalLayout(lines: lines, width: width, lineHeight: Self.pitch)
        let data = SampleData.terminalPNG(lines: lines, covered: false, width: width, lineHeight: Self.pitch)
        let image = try ImageCodec.decode(data).image
        let catalogue = try Catalogue.resolved()
        let scanner = ObscuraDetect.Scanner(catalogue: catalogue)
        // The first .accurate request in a process loads Vision's models (12–25 s measured); give it room.
        let reading = try await RecallPipeline.read(image, options: OCROptions(timeout: .seconds(120)),
                                                    queue: OCRQueue(recognizer: VisionTextRecognizer()), priority: .file, scanner: scanner)
        let detection = RecallPipeline.detect(reading, image: image, scanner: scanner,
                                              imageSize: CGSize(width: image.width, height: image.height), titles: [:])

        let font = CTFontCreateWithName("Menlo" as CFString, SampleData.TerminalLayout.fontSize, nil)
        let textHeight = (CTFontGetAscent(font) + CTFontGetDescent(font)) * layout.scale
        let equalsAdvance = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
            NSAttributedString(string: "=", attributes: [.font: font])), nil, nil, nil)) * layout.scale
        let rows = (1...Self.secrets.count).map { try! #require(layout.valueRect(line: $0)) }

        // Each cover belongs to the secret row whose centre is nearest its own.
        var perRow = [[DetectedArea]](repeating: [], count: rows.count)
        for area in detection.areas {
            let nearest = rows.indices.min { abs(rows[$0].midY - area.rect.midY) < abs(rows[$1].midY - area.rect.midY) }!
            perRow[nearest].append(area)
        }
        #expect(detection.areas.count == Self.secrets.count,
                "\(detection.areas.count) covers: \(detection.areas.map { "\($0.detectorIDs) \($0.rect.integral)" })")
        for (i, secret) in Self.secrets.enumerated() {
            #expect(perRow[i].count == 1, "line \(i + 1): \(perRow[i].count) covers")
            guard let cover = perRow[i].first else { continue }
            #expect(cover.detectorIDs.contains(secret.detector), "line \(i + 1): \(cover.detectorIDs)")
            #expect(cover.rect.height <= 1.6 * textHeight, "line \(i + 1): cover \(cover.rect.height) px tall, text \(textHeight) px")
            // The key name ends where the `=` cell starts; a cover may reach into the `=` but never left of it.
            #expect(cover.rect.minX >= rows[i].minX - equalsAdvance, "line \(i + 1): cover starts at \(cover.rect.minX), key name ends at \(rows[i].minX - equalsAdvance)")
        }
        return reading
    }
}
