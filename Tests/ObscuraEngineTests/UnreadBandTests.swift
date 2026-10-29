// Fail-open #1 (with #22): a G-12 re-read that could not read a band (no time left, a sheet that throws, a strip with no
// text at every scale, a tile left out of the stitch) used to return pass 1 alone, and the engine trusted it: an unread
// route-B band ended `.clean`, a long line kept pass 1's short cover, and with G-18 that "clean" picture went on the
// clipboard. Now the reading says which bands went unread and why; their lines are covered to the band's ink end; the
// picture ends "not checked" (a file row, the status count, the notice) and is never put on the clipboard. A sheet that
// throws no longer ends the re-read: the other sheets run, and its strips are retried. Every value is made up.
import AppKit
import CoreGraphics
import Foundation
import ObscuraDetect
import ObscuraJournal
@testable import ObscuraOCR
import ObscuraPrefs
import Testing
@testable import ObscuraEngine

/// Answers pass 1 with the long-line fixture's early-stopping reading, and each sheet request from `script`: the strips
/// the reader put on that sheet with the units of each to return (nil = all, 0 = nothing), or an error to throw.
struct LayoutSheetRecognizer: TextRecognizer {
    enum Answer: Sendable {
        case read([(strip: RereadStrip, keep: Int?)])
        case fail(OCRError)
    }

    let fixture: LongLineFixture
    let tuning: RecallTuning
    let script: @Sendable (_ call: Int) -> Answer
    let calls = SheetCalls()

    var rereadsPixels: Bool { true }

    func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading { fixture.pass1() }

    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        switch script(await calls.next()) {
        case .fail(let error):
            throw error
        case .read(let strips):
            guard let layout = RereadSheet.layout(strips.map(\.strip), maxSide: tuning.sheetMaxSide).first else { return [] }
            return layout.slots.compactMap { slot in
                let (strip, keep) = strips[slot.strip]
                if keep == 0 { return nil }
                return fixture.observation(strip: strip, slot: slot.rect, keep: keep)
            }
        }
    }
}

@Suite("Unread re-read bands are never trusted (fail-open #1, #22)")
struct UnreadBandTests {
    let fixture = LongLineFixture()

    func read(_ recognizer: LayoutSheetRecognizer, options: OCROptions = OCROptions()) async throws -> (RecallReading, ImageDetection) {
        let reading = try await RecallReader.read(fixture.image, options: options, recognizer: recognizer, tuning: recognizer.tuning) { _ in [] }
        let scanner = ObscuraDetect.Scanner(catalogue: try Catalogue.resolved(state: ["cloud.aws.sessiontoken": true]))
        let detection = RecallPipeline.detect(reading, image: fixture.image, scanner: scanner,
                                              imageSize: CGSize(width: fixture.image.width, height: fixture.image.height), titles: [:])
        return (reading, detection)
    }

    /// The strips of one attempt at `factor`, as the reader scales them.
    func scaled(_ strips: [RereadStrip], _ factor: CGFloat) -> [RereadStrip] {
        strips.map { RereadStrip(band: $0.band, tile: $0.tile, scale: max(1, $0.scale * factor)) }
    }

    @Test func aSheetThatThrowsNoLongerEndsTheReRead() async throws {
        let tuning = RecallTuning()
        let strips = fixture.strips(tuning: tuning)
        let recognizer = LayoutSheetRecognizer(fixture: fixture, tuning: tuning) { call in
            call == 0 ? .fail(.failed(underlying: CocoaError(.featureUnsupported))) : .read(scaled(strips, 1.25).map { ($0, nil) })
        }
        let (reading, detection) = try await read(recognizer)
        // The failed sheet's strips are read again at the next scale (the old reader stopped every attempt here).
        #expect(await recognizer.calls.count == 2)
        #expect(reading.stats.failedSheets == 1)
        #expect(reading.completeness.isComplete && reading.completeness.planned == 1 && reading.completeness.read == 1)
        #expect(reading.rereads.map(\.line.text) == [fixture.text])
        #expect(detection.conservativeAreas == 0)
        #expect(ShortRereadCoverTests().visibleTokenGlyphs(detection.areas).isEmpty)
    }

    @Test func theOtherSheetsOfAnAttemptStillRunAfterOneThrows() async throws {
        // A sheet too small for two strips: every strip is its own sheet, so the attempt has several.
        var tuning = RecallTuning()
        tuning.sheetMaxSide = 250
        let strips = fixture.strips(tuning: tuning)
        let first = RereadSheet.layout(strips, maxSide: tuning.sheetMaxSide)
        try #require(first.count >= 3)
        let firstSheet = first[0].slots.map { strips[$0.strip] }
        let recognizer = LayoutSheetRecognizer(fixture: fixture, tuning: tuning) { call in
            switch call {
            case 0: return .fail(.timeout)
            case 1..<first.count: return .read(first[call].slots.map { (strips[$0.strip], nil) })
            default: return .read(scaled(firstSheet, 1.25).map { ($0, nil) })
            }
        }
        let (reading, _) = try await read(recognizer)
        #expect(await recognizer.calls.count == first.count + 1, "every other sheet, then the failed sheet's strips again")
        #expect(reading.stats.failedSheets == 1)
        #expect(reading.completeness.isComplete)
    }

    @Test func aMiddleStripWithNoTextAtEveryScaleLeavesTheBandIncompleteAndCovered() async throws {
        let tuning = RecallTuning()
        let strips = fixture.strips(tuning: tuning)
        try #require(strips.count == 4)
        let recognizer = LayoutSheetRecognizer(fixture: fixture, tuning: tuning) { call in
            switch call {
            case 0: return .read(strips.enumerated().map { ($1, $0 == 1 ? 0 : nil) })
            case 1: return .read([(scaled([strips[1]], 1.25)[0], 0)])
            default: return .read([(scaled([strips[1]], 0.8)[0], 0)])
            }
        }
        let (reading, detection) = try await read(recognizer)
        #expect(await recognizer.calls.count == 1 + tuning.retryScales.count)
        let band = try #require(reading.completeness.incomplete.first)
        #expect(reading.completeness.incomplete.count == 1 && band.strips == 4 && band.readStrips == 3 && band.gaps == [.empty] && band.hasLines)
        #expect(reading.completeness.timedOut == false)
        #expect(reading.stats.unreadTiles == 1, "the stitch said which tile it had no reading for (#22)")
        #expect(reading.lines.allSatisfy { $0.shortRead?.cause == .unread })
        #expect(reading.rereads.allSatisfy { $0.line.shortRead?.cause == .unread })
        let visible = ShortRereadCoverTests().visibleTokenGlyphs(detection.areas)
        #expect(visible.isEmpty, "\(visible.count) token glyph(s) visible")
        #expect(ShortRereadCoverTests().touchedLabelGlyphs(detection.areas).isEmpty)
    }

    @Test func aSheetThatFailsEveryTimeLeavesTheLabelledValueCoveredToItsInk() async throws {
        let tuning = RecallTuning()
        let recognizer = LayoutSheetRecognizer(fixture: fixture, tuning: tuning) { _ in .fail(.failed(underlying: CocoaError(.featureUnsupported))) }
        let (reading, detection) = try await read(recognizer)
        // Every sheet, then G-32's last attempt (the full-width crop, then `.fast`), which fails too.
        #expect(await recognizer.calls.count == 1 + tuning.retryScales.count + 2)
        #expect(reading.completeness.lastAttempts.map(\.calls) == [2] && reading.completeness.lastAttempts.first?.readBy == nil)
        let band = try #require(reading.completeness.incomplete.first)
        #expect(band.readStrips == 0 && band.gaps == [.failed] && reading.completeness.timedOut == false)
        // Pass 1 read 92 of the token's 302 characters, too few for its detector: the labelled value is covered to the end
        // of the ink all the same.
        #expect(detection.conservativeAreas >= 1)
        #expect(ShortRereadCoverTests().visibleTokenGlyphs(detection.areas).isEmpty)
        #expect(ShortRereadCoverTests().touchedLabelGlyphs(detection.areas).isEmpty)
    }

    @Test func noTimeLeftForTheReReadIsATimeout() async throws {
        var tuning = RecallTuning()
        tuning.minimumRereadBudget = .seconds(60)                      // more than the 20 s deadline: never enough
        let recognizer = LayoutSheetRecognizer(fixture: fixture, tuning: tuning) { _ in .read([]) }
        let (reading, detection) = try await read(recognizer)
        #expect(await recognizer.calls.count == 0)
        let band = try #require(reading.completeness.incomplete.first)
        #expect(band.gaps == [.deadline] && reading.completeness.timedOut == true)
        #expect(ShieldEngine.unreadReason(reading.completeness) == .ocrTimeout)
        #expect(ShortRereadCoverTests().visibleTokenGlyphs(detection.areas).isEmpty)
    }
}

// MARK: - The engine's verdict

/// Pass 1 reads the engine fixture's lines and finds, on an empty row below them, text nobody read (route B); every
/// re-read sheet comes back empty, so that band is never read.
struct UnreadRowRecognizer: TextRecognizer {
    let lines: [OCRLine]
    var rereadsPixels: Bool { true }
    func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading {
        OCRReading(lines: lines, regions: [TextRegion(rect: CGRect(x: 20, y: 102, width: 300, height: 14))])
    }
    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] { [] }
}

@Suite("A partly read picture is not checked (fail-open #1)", .serialized)
struct PartlyReadVerdictTests {
    @Test func anUnreadRowWithNothingFoundIsNotCheckedNeverClean() async throws {
        let h = try Harness(recognizer: UnreadRowRecognizer(lines: [Fixture.plainLine]))
        defer { h.tearDown() }
        let outcome = await h.scan()
        #expect(outcome.skipReason == .textNotRead, "G-40 true wording: Vision answered with no text. Was \(outcome.statLabel)")
        #expect(outcome.needsAttention)
        #expect(!outcome.isClean)
    }

    @Test func aFileWithAnUnreadRowIsListedNotChecked() async throws {
        let h = try Harness(recognizer: UnreadRowRecognizer(lines: [Fixture.plainLine]))
        defer { h.tearDown() }
        let folder = try Fixture.tempDirectory("partly-read")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Screenshot partly read.png")
        try Fixture.pngData().write(to: file)
        let stream = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .downloads))
        let report = try #require(await collect(stream, count: 1, timeout: .seconds(10)).first)
        #expect(report.outcome.skipReason == .textNotRead, "G-40: the row is too large for the small-spot case; true wording")
        let rows = try await h.journal.uncheckedFiles()
        #expect(rows.count == 1 && rows.first?.reason == .textNotRead)
        #expect(await h.engine.currentStatus().problems.contains { $0.kind == .scanFailure })
    }

    @MainActor @Test func aCaughtScreenshotWithAnUnreadRowIsCoveredListedAndNotCopied() async throws {
        let rig = try ClipboardRig(recognizer: UnreadRowRecognizer(lines: [Fixture.keyLine, Fixture.plainLine]))
        defer { rig.tearDown() }
        let file = try rig.shot()
        let before = rig.board.changeCount
        let report = try #require(await rig.submit(file, origin: .screenshotFolder))
        // What was found is covered: the entry exists and the file on disk is the covered picture.
        guard case .redacted(let entryID, let findings, _) = report.outcome else { Issue.record("not redacted: \(report.outcome.statLabel)"); return }
        #expect(findings == 1)
        let onDisk = try Fixture.decode(try Data(contentsOf: file))
        #expect(!Fixture.differingPixels(onDisk, Fixture.whiteImage()).isEmpty)
        // ...but the picture is not called checked, and is not put on the clipboard (G-18).
        #expect(report.notes.contains(.partlyRead) && report.notes.partlyReadReason == .textNotRead, "G-40 true wording")
        #expect(rig.board.changeCount == before, "a picture that is not checked never goes on the clipboard")
        let status = await rig.engine.currentStatus()
        #expect(status.unchecked.count == 1 && status.unchecked.first?.reason == UncheckedReason.textNotRead.rawValue)
        #expect(status.problems.contains { $0.kind == .scanFailure })
        _ = entryID
    }

    @Test func aPartlyReadCatchKeepsItsUncheckedReason() {
        #expect(ShieldEngine.uncheckedReason(for: .redacted(entryID: UUID(), findings: 1, duration: .zero), notes: [.partlyRead]) == .ocrFailed)
        #expect(ShieldEngine.uncheckedReason(for: .redacted(entryID: UUID(), findings: 1, duration: .zero),
                                             notes: [.partlyRead, .partlyReadTimedOut]) == .ocrTimeout)
        #expect(ShieldEngine.uncheckedReason(for: .redacted(entryID: UUID(), findings: 1, duration: .zero), notes: []) == nil)
    }
}
