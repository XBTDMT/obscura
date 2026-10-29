// G-32: a band no G-12/G-22 re-read could read gets one bounded last attempt before it is left unread: the band cropped
// full-width at 1× with the accurate level, then, only if that reads nothing, the same crop at Vision's `.fast` level.
// At most two calls per band, each only while the image's deadline leaves the re-read's minimum budget; anything still
// unread ends "not checked" as fail-open #1 made it. Measured before G-32 (lane B, 4220491): network.ip.v4's
// `"service"` row, skipped by pass 1 and read as nothing by every re-read sheet, ended the picture "not checked".
// Every value is made up.
import CoreGraphics
import Foundation
import ObscuraDetect
@testable import ObscuraOCR
import Testing
@testable import ObscuraEngine

/// Which recognition a call was, told apart by what the reader asks for: a re-read sheet (strips stacked on a sheet of
/// its own size), the last attempt's full-width crop (the image's width) at the accurate level, or the same at `.fast`.
enum LastAttemptCall: Sendable, Hashable {
    case sheet
    case fullWidth
    case fast
}

actor LastAttemptLog {
    private(set) var calls: [LastAttemptCall] = []
    private(set) var cropHeights: [Int] = []
    private(set) var languages: [[String]] = []
    func record(_ call: LastAttemptCall, height: Int, languages: [String]) -> Int {
        calls.append(call)
        if call != .sheet {
            cropHeights.append(height)
            self.languages.append(languages)
        }
        return calls.filter { $0 == call }.count - 1
    }
    func count(_ call: LastAttemptCall) -> Int { calls.filter { $0 == call }.count }
    /// Calls of the last attempt: (full-width, fast).
    var extra: (fullWidth: Int, fast: Int) { (count(.fullWidth), count(.fast)) }
}

/// Pass 1 reads `lines` and finds text regions nobody read (route B). Every re-read sheet comes back empty, as Vision
/// answered for network.ip.v4's row; the last attempt's full-width crop and `.fast` read `text` when `readBy` says so.
struct LastAttemptRecognizer: TextRecognizer {
    let lines: [OCRLine]
    let regions: [TextRegion]
    let imageWidth: Int
    let readBy: Set<LastAttemptCall>
    var text = "service billing api"
    /// Slept by the n-th call of a kind (0-based), to spend the image's deadline.
    var delays: [LastAttemptCall: (call: Int, delay: Duration)] = [:]
    let log = LastAttemptLog()

    var rereadsPixels: Bool { true }

    func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading { OCRReading(lines: lines, regions: regions) }

    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        let call: LastAttemptCall = image.width != imageWidth ? .sheet : options.level == .fast ? .fast : .fullWidth
        let n = await log.record(call, height: image.height, languages: options.languages)
        if let delay = delays[call], delay.call == n { try await Task.sleep(for: delay.delay) }
        guard readBy.contains(call) else { return [] }
        // The crop's own coordinates (top-left, 1×): the row centred in it, where pass 1 found its region.
        let height: CGFloat = 14
        return [OCRLine(index: 0, text: text, rect: CGRect(x: 20, y: (CGFloat(image.height) - height) / 2, width: 300, height: height))]
    }
}

@Suite("A band no re-read could read gets one bounded last attempt (G-32)", .serialized)
struct LastAttemptTests {
    /// The engine fixture's plain line, and a region on the empty row below it that pass 1 did not read.
    static let unreadRow = TextRegion(rect: CGRect(x: 20, y: 102, width: 300, height: 14))

    func recognizer(readBy: Set<LastAttemptCall>, regions: [TextRegion] = [unreadRow], lines: [OCRLine] = [Fixture.plainLine],
                    text: String = "service billing api") -> LastAttemptRecognizer {
        LastAttemptRecognizer(lines: lines, regions: regions, imageWidth: Fixture.imageSize.width, readBy: readBy, text: text)
    }

    func read(_ recognizer: LastAttemptRecognizer, options: OCROptions = OCROptions(), tuning: RecallTuning = RecallTuning(),
              catalogue: [String: Bool] = [:]) async throws -> (RecallReading, ImageDetection) {
        let image = Fixture.whiteImage()
        let reading = try await RecallReader.read(image, options: options, recognizer: recognizer, tuning: tuning) { _ in [] }
        let scanner = ObscuraDetect.Scanner(catalogue: try Catalogue.resolved(state: catalogue))
        let detection = RecallPipeline.detect(reading, image: image, scanner: scanner,
                                              imageSize: CGSize(width: image.width, height: image.height), titles: [:])
        return (reading, detection)
    }

    // MARK: - Read by the full-width crop

    @Test func aRowTheReReadCouldNotReadIsReadByTheFullWidthCropAndThePictureIsClean() async throws {
        let r = recognizer(readBy: [.fullWidth])
        let (reading, _) = try await read(r)
        let tuning = RecallTuning()
        #expect(await r.log.count(.sheet) == 1 + tuning.retryScales.count, "the normal re-read and its retries ran first")
        #expect(await r.log.count(.fullWidth) == 1)
        #expect(await r.log.count(.fast) == 0, ".fast only when the full-width crop reads nothing")
        #expect(reading.completeness.isComplete)
        #expect(reading.completeness.lastAttempts == [ReadCompleteness.LastAttempt(band: 0, calls: 1, readBy: .fullWidth, skippedForDeadline: false)])
        #expect(reading.completeness.readByLastAttempt(.fullWidth) == 1)
        #expect(reading.stats.lastAttemptCalls == 1 && reading.stats.unreadBands == 0 && reading.stats.unreadTiles == 0)
        let added = try #require(reading.rereads.first)
        #expect(added.line.text == r.text && added.replaces.isEmpty)
        #expect(added.line.shortRead == nil, "the accurate model at 1× is trusted like any complete reading")
        // The crop is the band's rows at the image's full width and scale 1, read in pass 1's languages (G-31).
        let heights = await r.log.cropHeights
        #expect(heights.count == 1 && heights[0] >= 14 && heights[0] <= 30)
        #expect(await r.log.languages == [OCROptions().languages])
        // Its rect is back in image coordinates, on the unread row.
        #expect(abs(added.line.rect.midY - Self.unreadRow.rect.midY) <= 2)
        #expect(added.line.rect.minX >= Self.unreadRow.rect.minX - 2 && added.line.rect.maxX <= Self.unreadRow.rect.maxX + 2)
    }

    @Test func theEngineCallsAPictureWhoseRowTheFullWidthCropReadClean() async throws {
        let h = try Harness(recognizer: recognizer(readBy: [.fullWidth]))
        defer { h.tearDown() }
        let outcome = await h.scan()
        #expect(outcome.isClean, "was \(outcome.statLabel)")
        #expect(!outcome.needsAttention)
    }

    // MARK: - Read only by .fast

    @Test func aRowReadOnlyAtTheFastLevelIsReadAndItsLineIsCoveredConservatively() async throws {
        let r = recognizer(readBy: [.fast])
        let (reading, _) = try await read(r)
        #expect(await r.log.extra == (1, 1))
        #expect(reading.completeness.isComplete)
        #expect(reading.completeness.lastAttempts == [ReadCompleteness.LastAttempt(band: 0, calls: 2, readBy: .fast, skippedForDeadline: false)])
        let added = try #require(reading.rereads.first)
        #expect(added.line.text == r.text)
        #expect(added.line.shortRead?.cause == .fast, "a weaker model's line keeps G-22's conservative cover")
        #expect(await r.log.languages == [OCROptions().languages, OCROptions().languages])
    }

    @Test func theEngineCallsAPictureWhoseRowOnlyTheFastLevelReadClean() async throws {
        let h = try Harness(recognizer: recognizer(readBy: [.fast]))
        defer { h.tearDown() }
        let outcome = await h.scan()
        #expect(outcome.isClean, "was \(outcome.statLabel)")
    }

    @Test func aSecretTheLastAttemptReadsIsFoundAndCovered() async throws {
        // Text read here feeds detection like any other: a labelled made-up key on the row nobody else read.
        for reader in [LastAttemptCall.fullWidth, .fast] {
            let r = recognizer(readBy: [reader], text: "STRIPE_SECRET_KEY=\(Fixture.fakeKey)")
            let (reading, detection) = try await read(r, catalogue: ["payments.stripe.secretkey": true])
            #expect(reading.completeness.isComplete)
            let area = try #require(detection.areas.first { $0.detectorIDs.contains("payments.stripe.secretkey") }, "\(reader)")
            #expect(abs(area.placed.rect.midY - Self.unreadRow.rect.midY) <= 8)
            #expect(area.conservative == (reader == .fast), "\(reader): only the .fast line is covered conservatively")
        }
    }

    // MARK: - Read by neither

    @Test func aRowNeitherAttemptReadsStaysNotCheckedAsBefore() async throws {
        let r = recognizer(readBy: [])
        let (reading, _) = try await read(r)
        #expect(await r.log.extra == (1, 1))
        let band = try #require(reading.completeness.incomplete.first)
        // Exactly as fail-open #1 left it: the band unread for the reason the re-read gave, no line, the picture not checked.
        #expect(reading.completeness.incomplete.count == 1 && band.gaps == [.empty] && !band.hasLines && band.readStrips == 0)
        #expect(reading.completeness.lastAttempts == [ReadCompleteness.LastAttempt(band: 0, calls: 2, readBy: nil, skippedForDeadline: false)])
        #expect(reading.stats.unreadBands == 1 && reading.rereads.isEmpty)
        #expect(ShieldEngine.unreadReason(reading.completeness) == .textNotRead, "G-40 true wording: Vision answered every call with no text")

        let h = try Harness(recognizer: recognizer(readBy: []))
        defer { h.tearDown() }
        let outcome = await h.scan()
        #expect(outcome.skipReason == .textNotRead, "G-40: a 300 × 14 row is not a small spot on a 480 × 120 picture; was \(outcome.statLabel)")
        #expect(!outcome.isClean)
    }

    // MARK: - Bounded by the deadline, and by two calls

    @Test func withTheDeadlineNearlySpentTheLastAttemptIsSkippedAndTheRowStaysUnread() async throws {
        // A 3 s deadline with a 1 s minimum: the last re-read sheet takes 2.2 s, so less than the minimum is left.
        var tuning = RecallTuning()
        tuning.minimumRereadBudget = .seconds(1)
        var r = recognizer(readBy: [.fullWidth, .fast])
        r.delays = [.sheet: (call: tuning.retryScales.count, delay: .milliseconds(2200))]
        let (reading, _) = try await read(r, options: OCROptions(timeout: .seconds(3)), tuning: tuning)
        #expect(await r.log.count(.sheet) == 1 + tuning.retryScales.count)
        #expect(await r.log.extra == (0, 0), "no attempt past the deadline, none with a longer timeout")
        #expect(reading.completeness.lastAttempts == [ReadCompleteness.LastAttempt(band: 0, calls: 0, readBy: nil, skippedForDeadline: true)])
        let band = try #require(reading.completeness.incomplete.first)
        #expect(band.gaps == [.empty] && reading.rereads.isEmpty)
        #expect(ShieldEngine.unreadReason(reading.completeness) != nil)
    }

    @Test func aFullWidthCropThatSpendsTheDeadlineLeavesNoTimeForTheFastLevel() async throws {
        var tuning = RecallTuning()
        tuning.minimumRereadBudget = .seconds(1)
        var r = recognizer(readBy: [.fast])
        r.delays = [.fullWidth: (call: 0, delay: .milliseconds(2200))]
        let (reading, _) = try await read(r, options: OCROptions(timeout: .seconds(3)), tuning: tuning)
        #expect(await r.log.extra == (1, 0))
        #expect(reading.completeness.lastAttempts == [ReadCompleteness.LastAttempt(band: 0, calls: 1, readBy: nil, skippedForDeadline: true)])
        #expect(!reading.completeness.isComplete && reading.rereads.isEmpty)
    }

    @Test func neverMoreThanTwoExtraCallsPerBand() async throws {
        // Two rows nobody reads, on separate bands; nothing ever reads them.
        let regions = [TextRegion(rect: CGRect(x: 20, y: 30, width: 300, height: 14)), TextRegion(rect: CGRect(x: 40, y: 90, width: 280, height: 14))]
        let r = recognizer(readBy: [], regions: regions, lines: [])
        let (reading, _) = try await read(r)
        #expect(reading.stats.bands == 2)
        #expect(await r.log.extra == (2, 2))
        #expect(reading.completeness.lastAttempts.count == 2)
        #expect(reading.completeness.lastAttempts.allSatisfy { $0.calls <= 2 && $0.readBy == nil })
        #expect(reading.stats.lastAttemptCalls == 4)
        #expect(reading.completeness.incomplete.count == 2)
    }

    @Test func aBandTheReReadReadIsNeverGivenALastAttempt() async throws {
        // The normal re-read reads the row: no extra call.
        struct SheetReads: TextRecognizer {
            let log = LastAttemptLog()
            var rereadsPixels: Bool { true }
            func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading {
                OCRReading(lines: [Fixture.plainLine], regions: [LastAttemptTests.unreadRow])
            }
            func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
                _ = await log.record(image.width == Fixture.imageSize.width ? .fullWidth : .sheet, height: image.height, languages: options.languages)
                // One observation on the sheet's single slot, wherever the layout put it: the sheet's middle.
                return [OCRLine(index: 0, text: "service billing api", rect: CGRect(x: 8, y: CGFloat(image.height) / 2 - 20, width: CGFloat(image.width) - 16, height: 40))]
            }
        }
        let r = SheetReads()
        let reading = try await RecallReader.read(Fixture.whiteImage(), options: OCROptions(), recognizer: r) { _ in [] }
        #expect(reading.completeness.isComplete && reading.rereads.count == 1)
        #expect(reading.completeness.lastAttempts.isEmpty && reading.stats.lastAttemptCalls == 0)
        #expect(await r.log.count(.fullWidth) == 0)
    }
}
