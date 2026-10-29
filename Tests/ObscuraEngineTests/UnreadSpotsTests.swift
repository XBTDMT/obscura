// G-40: a picture whose only unread parts are small spots no reading could read. Stub readings (no Vision): pass 1 finds
// a text region nobody read, every re-read sheet and both G-32 last attempts answer with no text. The ruling's case C
// (listed under Not checked as `unreadPatch`, no alarm, rects kept, settled by the person), the opt-in B (covered, padded)
// and D (skipped when too small for the shortest enabled secret), and everything outside the case keeping today's outcome.
// Every value is made up.
import CoreGraphics
import Foundation
import ObscuraCapture
import ObscuraDetect
import ObscuraJournal
@testable import ObscuraOCR
import ObscuraPrefs
import Testing
@testable import ObscuraEngine

/// Pass 1 reads `lines` and finds `regions` nobody read. Every re-read sheet answers with no text; the last attempt's
/// full-width crop (the image's own width) answers with no text too, unless told to fail or to time out.
struct SpotRecognizer: TextRecognizer {
    var lines: [OCRLine] = []
    var regions: [TextRegion]
    var lastAttemptFails = false
    var sheetsTimeOut = false

    var rereadsPixels: Bool { true }

    func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading { OCRReading(lines: lines, regions: regions) }

    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        let lastAttempt = image.width == Fixture.imageSize.width
        if !lastAttempt && sheetsTimeOut { throw OCRError.timeout }
        if lastAttempt && lastAttemptFails { throw OCRError.failed(underlying: CocoaError(.featureUnsupported)) }
        return []
    }
}

enum SpotFixture {
    /// A 40 × 8 px mark on the 480 × 120 picture: 0.56 % of it (under `UnreadSpots.maxAreaFraction`), five heights wide
    /// (route B's gate is four), on a row nothing else was read on.
    static let mark = TextRegion(rect: CGRect(x: 100, y: 100, width: 40, height: 8))
    /// Its re-read band: one advance (0.6 × 8 = 4.8 px, no glyph boxes) each side and 0.35 line heights above and below,
    /// rounded out; and the cover: that band plus one line height (8 px) on every side.
    static let band = CGRect(x: 95, y: 97, width: 50, height: 14)
    static let cover = CGRect(x: 87, y: 89, width: 66, height: 30)

    /// A file in a watched Downloads folder of the harness.
    static func file(_ h: Harness, name: String = "Photo with a mark.png") throws -> URL {
        let folder = try Fixture.tempDirectory("spots")
        h.watch(folder, as: .downloads)
        let url = folder.appendingPathComponent(name)
        try Fixture.pngData().write(to: url)
        return url
    }

    static func check(_ h: Harness, _ url: URL) async throws -> ScanReport {
        let stream = h.engine.outcomes
        await h.engine.submit(.file(url, origin: .downloads))
        return try #require(await collect(stream, count: 1, timeout: .seconds(10)).first)
    }

    /// Every built-in detector off but `keep`, so the shortest enabled secret is long.
    static func only(_ keep: Set<String>, in h: Harness) async throws {
        for detector in Catalogue.builtIn { try await h.journal.setDetectorEnabled(detector.id, enabled: keep.contains(detector.id)) }
        await h.engine.catalogueChanged()
    }
}

@Suite("Small spots no reading could read (G-40)", .serialized)
struct UnreadSpotsTests {
    // MARK: - The case's criteria

    func completeness(_ recognizer: SpotRecognizer) async throws -> ReadCompleteness {
        try await RecallReader.read(Fixture.whiteImage(), options: OCROptions(), recognizer: recognizer) { _ in [] }.completeness
    }

    static let size = CGSize(width: Fixture.imageSize.width, height: Fixture.imageSize.height)

    @Test func aSmallRegionNobodyReadsIsTheCaseWithItsRectsAndPaddedCover() async throws {
        let c = try await completeness(SpotRecognizer(regions: [SpotFixture.mark]))
        let band = try #require(c.incomplete.first)
        #expect(band.reasons == [.unread] && !band.hasLines && band.gaps == [.empty])
        #expect(band.core == SpotFixture.mark.rect && band.rect == SpotFixture.band && band.lineHeight == 8)
        #expect(c.lastAttempts.map(\.answered) == [2])
        let spots = try #require(UnreadSpots.patchCase(c, imageSize: Self.size))
        #expect(spots == [UnreadSpot(rect: SpotFixture.mark.rect, coverRect: SpotFixture.cover)])
        // The cover reaches at least one line height past the re-read band on every side.
        #expect(SpotFixture.cover.insetBy(dx: 8, dy: 8) == SpotFixture.band)
    }

    @Test func aLargeRegionIsNotTheCaseAndKeepsTodaysAlarmInTrueWords() async throws {
        // 300 × 14 = 6 % of the picture.
        let c = try await completeness(SpotRecognizer(regions: [TextRegion(rect: CGRect(x: 20, y: 100, width: 300, height: 14))]))
        #expect(UnreadSpots.patchCase(c, imageSize: Self.size) == nil)
        #expect(ShieldEngine.unreadReason(c) == .textNotRead)
    }

    @Test func aBandBesideReadTextIsNotTheCase() async throws {
        // A line read on the same row, touching the mark: the band replaces it (it has lines), so it is not a lone spot.
        let line = OCRLine(index: 0, text: "token", rect: CGRect(x: 60, y: 100, width: 38, height: 8))
        let c = try await completeness(SpotRecognizer(lines: [line], regions: [SpotFixture.mark]))
        #expect(c.incomplete.first?.hasLines == true)
        #expect(UnreadSpots.patchCase(c, imageSize: Self.size) == nil)
    }

    @Test func aBandThatTimedOutIsNotTheCase() async throws {
        let c = try await completeness(SpotRecognizer(regions: [SpotFixture.mark], sheetsTimeOut: true))
        #expect(c.incomplete.first?.gaps.contains(.timeout) == true)
        #expect(UnreadSpots.patchCase(c, imageSize: Self.size) == nil)
        #expect(ShieldEngine.unreadReason(c) == .ocrTimeout)
    }

    @Test func aLastAttemptVisionDidNotAnswerIsNotTheCase() async throws {
        let c = try await completeness(SpotRecognizer(regions: [SpotFixture.mark], lastAttemptFails: true))
        #expect(c.lastAttempts.first.map { $0.calls == 2 && $0.answered == 0 } == true)
        #expect(UnreadSpots.patchCase(c, imageSize: Self.size) == nil)
    }

    @Test func spotsTogetherOverTheAreaLimitAreNotTheCase() {
        // Two lone bands, each small, together over 1 % of the picture.
        var c = ReadCompleteness()
        for (i, x) in [10.0, 200.0].enumerated() {
            let core = CGRect(x: x, y: 50, width: 40, height: 8)
            c.incomplete.append(.init(band: i, reasons: [.unread], strips: 1, readStrips: 0, gaps: [.empty], hasLines: false,
                                      rect: core.insetBy(dx: -5, dy: -3), core: core, lineHeight: 8))
            c.lastAttempts.append(.init(band: i, calls: 2, readBy: nil, skippedForDeadline: false))
        }
        #expect(UnreadSpots.patchCase(c, imageSize: CGSize(width: 480, height: 120)) == nil, "640 px of 57,600 is over 1 %")
        #expect(UnreadSpots.patchCase(c, imageSize: CGSize(width: 960, height: 120))?.count == 2, "under 1 % of a picture twice as wide")
    }

    @Test func aBandPlannedForAnotherReasonOrSkippedForTheDeadlineIsNotTheCase() {
        let core = CGRect(x: 10, y: 50, width: 40, height: 8)
        func with(reasons: Set<RereadReason>, skipped: Bool) -> ReadCompleteness {
            var c = ReadCompleteness()
            c.incomplete = [.init(band: 0, reasons: reasons, strips: 1, readStrips: 0, gaps: [.empty], hasLines: false,
                                  rect: core.insetBy(dx: -5, dy: -3), core: core, lineHeight: 8)]
            c.lastAttempts = [.init(band: 0, calls: skipped ? 1 : 2, readBy: nil, skippedForDeadline: skipped)]
            return c
        }
        #expect(UnreadSpots.patchCase(with(reasons: [.unread], skipped: false), imageSize: Self.size) != nil)
        #expect(UnreadSpots.patchCase(with(reasons: [.unread, .label], skipped: false), imageSize: Self.size) == nil)
        #expect(UnreadSpots.patchCase(with(reasons: [.unread], skipped: true), imageSize: Self.size) == nil)
    }

    /// The same picture with made-up unreadable text outside the case keeps today's outcome and alarm: a row too large,
    /// one that timed out, one whose last attempt Vision did not answer.
    @Test(arguments: [
        ("large", SkipReason.textNotRead),
        ("timedOut", SkipReason.ocrTimeout),
        ("unanswered", SkipReason.ocrFailed),
    ])
    func outsideTheCaseThePictureKeepsTodaysAlarm(_ variant: String, _ reason: SkipReason) async throws {
        let recognizer: SpotRecognizer
        switch variant {
        case "large": recognizer = SpotRecognizer(regions: [TextRegion(rect: CGRect(x: 20, y: 100, width: 300, height: 14))])
        case "timedOut": recognizer = SpotRecognizer(regions: [SpotFixture.mark], sheetsTimeOut: true)
        default: recognizer = SpotRecognizer(regions: [SpotFixture.mark], lastAttemptFails: true)
        }
        var settings = Settings.default
        settings.coversUnreadableSpots = true
        settings.skipsTinySpots = true
        let h = try Harness(recognizer: recognizer, settings: settings)
        defer { h.tearDown() }
        let report = try await SpotFixture.check(h, try SpotFixture.file(h))
        #expect(report.outcome.skipReason == reason, "\(variant): was \(report.outcome.statLabel)")
        #expect(report.spots.isEmpty && !report.notes.contains(.unreadSpots), "\(variant): neither switch applies outside the case")
        let status = await h.engine.currentStatus()
        #expect(status.problems.contains { $0.kind == .scanFailure }, "\(variant): today's alarm")
        #expect(!status.problems.contains { $0.kind == .unreadSpots })
    }

    // MARK: - C: listed, quiet, never clean

    @Test func theCaseIsListedWithItsSpotsNoAlarmAndNeverClean() async throws {
        let h = try Harness(recognizer: SpotRecognizer(regions: [SpotFixture.mark]))
        defer { h.tearDown() }
        let url = try SpotFixture.file(h)
        let report = try await SpotFixture.check(h, url)
        #expect(report.outcome.skipReason == .unreadPatch)
        #expect(!report.outcome.isClean && report.notes.contains(.unreadSpots))
        #expect(report.spots == [SpotRecord(rect: SpotFixture.mark.rect, coverRect: SpotFixture.cover, state: .pending)])
        let rows = try await h.journal.uncheckedFiles()
        #expect(rows.count == 1 && rows.first?.reason == .unreadPatch && rows.first?.spots == report.spots)
        #expect(try await h.journal.entries(matching: .all).isEmpty, "nothing covered, no entry, the file untouched")
        #expect(try Data(contentsOf: url) == Fixture.pngData())
        let status = await h.engine.currentStatus()
        // Quiet: a spots row, never the "weren't checked" alarm, and protection is not "needs attention".
        #expect(!status.problems.contains { $0.kind == .scanFailure })
        #expect(status.problems.contains { $0.kind == .unreadSpots && $0.detail == "1" && $0.url?.path == url.path })
        if case .needsAttention = status.protection { Issue.record("spots waiting must not raise needs attention") }
        #expect(status.unchecked.first?.isUnreadSpots == true)
    }

    @Test func aCatchWithASpotIsCoveredListedAndNotOnTheClipboard() async throws {
        let h = try Harness(recognizer: SpotRecognizer(lines: [Fixture.keyLine], regions: [SpotFixture.mark]))
        defer { h.tearDown() }
        let url = try SpotFixture.file(h)
        let report = try await SpotFixture.check(h, url)
        guard case .redacted(let entryID, let findings, _) = report.outcome else { Issue.record("not redacted: \(report.outcome.statLabel)"); return }
        #expect(findings == 1)
        #expect(report.notes.contains(.unreadSpots) && !report.notes.contains(.partlyRead), "no alarm: the spot waits for the person")
        let row = try #require(try await h.journal.uncheckedFiles().first)
        #expect(row.reason == .unreadPatch && row.spots.map(\.entryID) == [entryID] && row.spots.map(\.state) == [.pending])
    }

    // MARK: - B: covered when the switch is on

    @Test func withCoverOnTheSpotIsCoveredPaddedAndTheCountSaid() async throws {
        var settings = Settings.default
        settings.coversUnreadableSpots = true
        let h = try Harness(recognizer: SpotRecognizer(regions: [SpotFixture.mark]), settings: settings)
        defer { h.tearDown() }
        let url = try SpotFixture.file(h)
        let report = try await SpotFixture.check(h, url)
        guard case .redacted(let entryID, _, _) = report.outcome else { Issue.record("not covered: \(report.outcome.statLabel)"); return }
        #expect(report.notes.contains(.spotsCovered) && !report.notes.contains(.unreadSpots))
        #expect(report.coveredSpots == 1)
        let entry = try await h.journal.entry(entryID)
        let cover = try #require(entry.findings.first)
        #expect(entry.findings.count == 1 && cover.isSpotCover && cover.rect == SpotFixture.cover && cover.enabled)
        #expect(entry.secretFindings.isEmpty && entry.spotCovers.count == 1, "a spot's cover is not a secret")
        // The file holds the covered picture; the spot is the record, not a listing.
        #expect(try Data(contentsOf: url) != Fixture.pngData())
        #expect(try await h.journal.uncheckedFiles().isEmpty)
        let record = try #require(try await h.journal.settledSpotFiles().first)
        #expect(record.spots.map(\.state) == [.covered] && record.spots.first?.findingID == cover.id)
        // Counted as checked, not as a caught secret.
        #expect(try await h.journal.weekStats().last?.secrets == 0)
    }

    @Test func undoingACoveredSpotListsItAgain() async throws {
        var settings = Settings.default
        settings.coversUnreadableSpots = true
        let h = try Harness(recognizer: SpotRecognizer(regions: [SpotFixture.mark]), settings: settings)
        defer { h.tearDown() }
        let url = try SpotFixture.file(h)
        let report = try await SpotFixture.check(h, url)
        guard case .redacted(let entryID, _, _) = report.outcome else { Issue.record("not covered"); return }
        try await h.engine.restoreOriginal(entryID)
        let listed = try #require(try await h.journal.uncheckedFiles().first, "the original shows its spot again: it waits")
        #expect(listed.spots.map(\.state) == [.pending])
        #expect(await h.engine.currentStatus().unchecked.count == 1)
        try await h.engine.blackOutAll(entryID)
        #expect(try await h.journal.uncheckedFiles().isEmpty)
    }

    // MARK: - D: skipped when too small for every enabled secret

    @Test func theCapacityIsTheWidthOverTheNarrowestAdvanceRoundedUp() {
        // 40 / (0.3 × 8) = 16.7 → 17 glyphs.
        #expect(UnreadSpots.capacity(of: UnreadSpot(rect: SpotFixture.mark.rect, coverRect: SpotFixture.cover)) == 17)
        // Route B never plans a region narrower than four heights, so no spot holds fewer than 14.
        #expect(UnreadSpots.capacity(of: UnreadSpot(rect: CGRect(x: 0, y: 0, width: 40, height: 10), coverRect: .zero)) == 14)
    }

    @Test func withTheDefaultDetectorsNoSpotIsSmallEnoughToSkip() async throws {
        var settings = Settings.default
        settings.skipsTinySpots = true
        let h = try Harness(recognizer: SpotRecognizer(regions: [SpotFixture.mark]), settings: settings)
        defer { h.tearDown() }
        let report = try await SpotFixture.check(h, try SpotFixture.file(h))
        // Five default detectors report a password of one character (a database URL's, JDBC, MongoDB, basic auth, netrc).
        #expect(report.outcome.skipReason == .unreadPatch)
        #expect(report.spots.map(\.state) == [.pending])
    }

    @Test func aSpotNarrowerThanEveryEnabledSecretIsSkippedAndRecorded() async throws {
        var settings = Settings.default
        settings.skipsTinySpots = true
        let h = try Harness(recognizer: SpotRecognizer(regions: [SpotFixture.mark]), settings: settings)
        defer { h.tearDown() }
        // Only a detector whose shortest secret is far longer than the spot's 17 glyphs.
        try await SpotFixture.only(["cloud.aws.sessiontoken"], in: h)
        let url = try SpotFixture.file(h)
        let report = try await SpotFixture.check(h, url)
        #expect(report.outcome.isClean, "was \(report.outcome.statLabel)")
        #expect(report.notes.contains(.spotsSkipped))
        #expect(report.spots.map(\.state) == [.tooSmall])
        #expect(try await h.journal.uncheckedFiles().isEmpty)
        let record = try #require(try await h.journal.settledSpotFiles().first, "never silent: the skipped spot is recorded")
        #expect(record.spots == [SpotRecord(rect: SpotFixture.mark.rect, coverRect: SpotFixture.cover, state: .tooSmall)])
        #expect(try Data(contentsOf: url) == Fixture.pngData(), "a skipped spot is not covered")
    }

    @Test func aCustomRuleShorterThanTheSpotKeepsItWaiting() async throws {
        var settings = Settings.default
        settings.skipsTinySpots = true
        let h = try Harness(recognizer: SpotRecognizer(regions: [SpotFixture.mark]), settings: settings)
        defer { h.tearDown() }
        try await SpotFixture.only(["cloud.aws.sessiontoken"], in: h)
        try await h.journal.upsertRule(RuleRecord(action: .blackOut, kind: .exactText, value: "zq7x", createdAt: Date(), sortOrder: 0))
        await h.engine.catalogueChanged()
        let report = try await SpotFixture.check(h, try SpotFixture.file(h))
        #expect(report.outcome.skipReason == .unreadPatch && report.spots.map(\.state) == [.pending])
    }

    @Test func skipDecidesFirstAndCoverCoversWhatSkipLeaves() {
        let small = UnreadSpot(rect: CGRect(x: 0, y: 0, width: 40, height: 8), coverRect: .zero)     // capacity 17
        let wide = UnreadSpot(rect: CGRect(x: 0, y: 20, width: 200, height: 8), coverRect: .zero)    // capacity 84
        #expect(UnreadSpots.decide([small, wide], skipsTiny: true, covers: true, shortestSecret: 40) == [.tooSmall, .covered])
        #expect(UnreadSpots.decide([small, wide], skipsTiny: true, covers: false, shortestSecret: 40) == [.tooSmall, .pending])
        #expect(UnreadSpots.decide([small, wide], skipsTiny: false, covers: true, shortestSecret: 40) == [.covered, .covered])
        #expect(UnreadSpots.decide([small], skipsTiny: true, covers: false, shortestSecret: 17) == [.pending], "strictly below")
        #expect(UnreadSpots.decide([small], skipsTiny: true, covers: false, shortestSecret: 18) == [.tooSmall])
        #expect(UnreadSpots.decide([small], skipsTiny: true, covers: false, shortestSecret: nil) == [.pending])
    }

    // MARK: - The person settles it

    @Test func notTextSettlesItAsTheirsAndUndoListsItAgain() async throws {
        let h = try Harness(recognizer: SpotRecognizer(regions: [SpotFixture.mark]))
        defer { h.tearDown() }
        let url = try SpotFixture.file(h)
        _ = try await SpotFixture.check(h, url)
        let file = try #require(await h.engine.currentStatus().unchecked.first)
        let after = try await h.engine.settleSpots(file, .notText)
        #expect(after.spots.map(\.state) == [.notText] && after.settledAt != nil)
        #expect(await h.engine.currentStatus().unchecked.isEmpty)
        #expect(!(await h.engine.currentStatus().problems.contains { $0.kind == .unreadSpots }))
        #expect(try await h.journal.entries(matching: .all).isEmpty, "never called clean: nothing is written, the person's word is recorded")
        #expect(try await h.journal.settledSpotFiles().first?.spots.map(\.state) == [.notText])

        let back = try await h.engine.undoSettleSpots(file)
        #expect(back.spots.map(\.state) == [.pending] && back.settledAt == nil)
        #expect(await h.engine.currentStatus().unchecked.map(\.id) == [file.id])
    }

    @Test func coverItCoversThePaddedSpotKeepsTheOriginalAndUndoes() async throws {
        let h = try Harness(recognizer: SpotRecognizer(regions: [SpotFixture.mark]))
        defer { h.tearDown() }
        let url = try SpotFixture.file(h)
        _ = try await SpotFixture.check(h, url)
        let file = try #require(await h.engine.currentStatus().unchecked.first)
        let after = try await h.engine.settleSpots(file, .cover)
        let spot = try #require(after.spots.first)
        #expect(spot.state == .covered && after.settledAt != nil)
        let entryID = try #require(spot.entryID)
        let entry = try await h.journal.entry(entryID)
        #expect(entry.findings.map(\.rect) == [SpotFixture.cover] && entry.findings.allSatisfy { $0.isSpotCover && $0.enabled })
        #expect(try await h.journal.originalData(entryID) == Fixture.pngData(), "the original is kept in the Journal")
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk != Fixture.pngData(), "the file is rewritten with the cover")
        #expect(await h.engine.currentStatus().unchecked.isEmpty)

        let back = try await h.engine.undoSettleSpots(file)
        #expect(back.spots.map(\.state) == [.pending] && back.settledAt == nil)
        #expect(try Data(contentsOf: url) == Fixture.pngData(), "undo puts the original back")
        #expect(try await h.journal.entry(entryID).enabledFindings.isEmpty)
        // A second Cover It uses the same cover again.
        let again = try await h.engine.settleSpots(back, .cover)
        #expect(again.spots.first?.findingID == spot.findingID)
        #expect(try await h.journal.entry(entryID).findings.count == 1)
    }

    @Test func coverItOnACatchAddsTheCoverToItsEntry() async throws {
        let h = try Harness(recognizer: SpotRecognizer(lines: [Fixture.keyLine], regions: [SpotFixture.mark]))
        defer { h.tearDown() }
        let url = try SpotFixture.file(h)
        let report = try await SpotFixture.check(h, url)
        guard case .redacted(let entryID, _, _) = report.outcome else { Issue.record("not redacted"); return }
        let file = try #require(await h.engine.currentStatus().unchecked.first)
        let after = try await h.engine.settleSpots(file, .cover)
        #expect(after.spots.first?.entryID == entryID && after.settledAt != nil)
        let entry = try await h.journal.entry(entryID)
        #expect(entry.secretFindings.count == 1 && entry.spotCovers.map(\.rect) == [SpotFixture.cover])
        #expect(entry.enabledFindings.count == 2)
    }
}
