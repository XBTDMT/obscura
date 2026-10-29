// Fail-open #20 through the engine's read path: RecallPipeline scans OCR text as `.recognized`, so a GitHub token whose
// checksum two misread characters broke is placed and covered (flagged unverified) instead of dropped. Made-up token.
import CoreGraphics
import Foundation
import ObscuraDetect
import ObscuraOCR
import Testing
@testable import ObscuraEngine

@Suite("Unverified vendor-format cover in the pipeline (fail-open #20)")
struct UnverifiedCoverTests {
    @Test func aMisreadGitHubTokenIsCoveredUnverified() throws {
        var chars = Array("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")
        chars[9] = "Q"; chars[20] = "w"
        let text = "GH=" + String(chars)
        let line = OCRLine(index: 0, text: text, rect: CGRect(x: 10, y: 10, width: CGFloat(text.utf16.count) * 10, height: 20))
        // The engine hands the pipeline a scanner built for exact text; the pipeline reads OCR text with it.
        let scanner = ObscuraDetect.Scanner(catalogue: try Catalogue.resolved(state: ["scm.github.token": true]))
        try #require(scanner.scan([ScanLine(index: 0, text: text)]).isEmpty, "exact text: the checksum rejects it")
        let detection = RecallPipeline.detect(RecallReading(lines: [line]), scanner: scanner, imageSize: CGSize(width: 600, height: 40),
                                              titles: [:])
        let area = try #require(detection.areas.first { $0.detectorIDs.contains("scm.github.token") })
        #expect(area.unverified && detection.unverifiedAreas == 1)
        // The line is 43 units of 10 px from x 10: the token runs from x 40 to the line's end at x 440.
        #expect(area.rect.minX <= 40 && area.rect.maxX >= 440)
    }
}
