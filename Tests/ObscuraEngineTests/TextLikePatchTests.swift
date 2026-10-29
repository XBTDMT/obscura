// G-40 (ruled 2026-10-28: C, with B and D as opt-in switches): a photo whose only "unread text" is a text-like patch
// Vision's text-rectangle detector flags and its recognizer never reads. Reproduced 2026-10-28 from a person's Downloads
// photo (2640×1240, one 66×16 px region with five character boxes, never read at any scale or level); this fixture is
// MADE UP: four dark ovals and a slash on a speckled grey, drawn by `TextLikePatchFixture.draw()` below, with no text in
// it at all.
//
// The reading is as before (fail-open #1 + G-32): the region is planned as a route-B band, every re-read and both last
// attempts read nothing, the band ends incomplete with no lines and gap `empty`. What the engine makes of it is the
// ruling: the picture is the small-spot case, listed under Not checked as `unreadPatch` with the patch's rect, no alarm;
// with "Cover spots Obscura can't read" on it is covered, padded; "Skip spots too small to hold a secret" does not skip
// it (its 17-glyph capacity is not below the shortest enabled secret, 1). Real Vision: skipped under CI, like the other
// Vision tests; a macOS update that changes Vision can change what the patch reads as, and this test is where that shows.
import CoreGraphics
import Foundation
import ImageIO
@testable import ObscuraOCR
import Testing
import ObscuraDetect
import ObscuraPrefs
@testable import ObscuraEngine

/// The made-up fixture: `Tests/Fixtures/unread-regions/text-like-patch.png`.
enum TextLikePatchFixture {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/unread-regions/text-like-patch.png")
    static let size = (width: 2640, height: 1240)
    /// Where the detector finds the patch (measured 2026-10-28; top-left origin, image pixels).
    static let patch = CGRect(x: 1875, y: 298, width: 68, height: 14)

    /// A flat mid-grey picture the size of the person's photo, speckled with fine grey noise in a 400 × 400 box, and in it
    /// four dark ovals and a slash in a row ("pebbles"). Measured: without the speckle, or on a 1320-wide canvas, Vision
    /// either finds no region or reads the row as text; with both, the detector finds a region the recognizer never reads.
    static func draw() -> CGImage {
        let w = size.width, h = size.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var seed: UInt64 = 128
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let box = CGRect(x: 1700, y: 100, width: 400, height: 400)
        for _ in 0..<(Int(box.width * box.height) / 40) {
            let x = box.minX + next() * box.width, y = box.minY + next() * box.height, v = next()
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 0.08))
            ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
        }
        let ink = CGColor(gray: 0.1736, alpha: 1)
        ctx.setFillColor(ink); ctx.setStrokeColor(ink)
        ctx.fillEllipse(in: CGRect(x: 1875.16, y: 299.42, width: 10.54, height: 8.02))
        ctx.fillEllipse(in: CGRect(x: 1889.41, y: 298.93, width: 15.95, height: 9.32))
        ctx.fillEllipse(in: CGRect(x: 1906.39, y: 299.47, width: 15.51, height: 11.58))
        ctx.fillEllipse(in: CGRect(x: 1924.94, y: 301.19, width: 3.98, height: 10.53))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: 1933.53, y: 309.75)); ctx.addLine(to: CGPoint(x: 1942.61, y: 298.43)); ctx.strokePath()
        return ctx.makeImage()!
    }

    static func data() throws -> Data { try Data(contentsOf: url) }

    static func image() throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(try data() as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}

@Suite("A text-like patch no reading can read is a spot for the person to settle (G-40)", .serialized)
struct TextLikePatchTests {
    /// Writes the fixture from `draw()`. Run by hand only (`OBSCURA_WRITE_FIXTURES=1`), never in the default suite.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBSCURA_WRITE_FIXTURES"] != nil))
    func writeFixture() throws {
        try FileManager.default.createDirectory(at: TextLikePatchFixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(TextLikePatchFixture.url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, TextLikePatchFixture.draw(), nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// The fixture is the picture `draw()` makes: same size, and the patch's ink where `draw()` puts it.
    @Test func theFixtureIsThePictureTheGeneratorDraws() throws {
        let image = try TextLikePatchFixture.image()
        #expect(image.width == TextLikePatchFixture.size.width && image.height == TextLikePatchFixture.size.height)
        let profile = try #require(InkCells.profile(image, rect: TextLikePatchFixture.patch, glyphs: []))
        #expect(!profile.boxes.isEmpty)
    }

    /// Pass 1, the plan, every re-read and both G-32 last attempts, with real Vision: the detector's region is planned as
    /// a route-B band, nothing reads it, and the reading says so.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func theDetectorFindsARegionNoReadingReads() async throws {
        let image = try TextLikePatchFixture.image()
        // Vision's first request loads its models (12–25 s cold); the read under test then runs warm.
        _ = try await VisionTextRecognizer().recognize(image, options: OCROptions(timeout: .seconds(120)))

        let first = try await VisionTextRecognizer().read(image, options: OCROptions(timeout: .seconds(60)))
        let region = try #require(first.regions.first { $0.rect.intersects(TextLikePatchFixture.patch) })
        #expect(region.rect.width >= RecallTuning().minUnreadAspect * region.rect.height)
        #expect(RereadPlanner.coveredFraction(region.rect, by: first.lines) < RecallTuning().unreadCoverage)
        #expect(!first.lines.contains { $0.rect.intersects(region.rect) })

        let reading = try await RecallReader.read(image, options: OCROptions(timeout: .seconds(60)), recognizer: VisionTextRecognizer()) { _ in [] }
        let completeness = reading.completeness
        let band = try #require(completeness.incomplete.first)
        #expect(completeness.incomplete.count == 1)
        #expect(band.reasons == [.unread])
        #expect(band.readStrips == 0)
        #expect(band.gaps == [.empty])
        #expect(!band.hasLines)
        // G-32's last attempt ran in full (the full-width crop, then `.fast`) and read nothing of the band.
        #expect(completeness.lastAttempts.map(\.calls) == [2])
        #expect(completeness.lastAttempts.allSatisfy { $0.readBy == nil && !$0.skippedForDeadline })
        #expect(reading.rereads.isEmpty)
        // Not a matter of time: Vision answered every call, with no text.
        #expect(completeness.timedOut == false)
        #expect(completeness.lastAttempts.map(\.answered) == [2])
        // G-40: the small-spot case, with the detector's region as the spot and the band, padded, as its cover.
        let spots = try #require(UnreadSpots.patchCase(completeness, imageSize: CGSize(width: image.width, height: image.height)))
        #expect(spots.count == 1)
        let spot = try #require(spots.first)
        #expect(spot.rect == band.core && band.core.intersects(TextLikePatchFixture.patch))
        #expect(spot.coverRect.contains(band.rect.insetBy(dx: -band.lineHeight, dy: -band.lineHeight).intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height))))
        // D's arithmetic on this patch: 68 / (0.3 × 14) = 16.2 → 17 glyphs, against the shortest enabled secret, 1.
        #expect(UnreadSpots.capacity(of: spot) == 17)
        let catalogue = try ObscuraDetect.Catalogue.resolved()
        #expect(catalogue.shortestSecretLength == 1)
        #expect(!UnreadSpots.isTooSmall(spot, shortestSecret: catalogue.shortestSecretLength))
    }

    /// The engine end to end on the fixture as a Downloads file: listed under Not checked as `unreadPatch` with the
    /// patch's rect, no alarm, never clean, the file untouched and no Journal entry.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func theEngineListsThePhotoAsASpotToSettle() async throws {
        let h = try Harness(recognizer: VisionTextRecognizer())
        defer { h.tearDown() }
        _ = try await VisionTextRecognizer().recognize(try TextLikePatchFixture.image(), options: OCROptions(timeout: .seconds(120)))
        let url = try Self.downloadsFile(h)
        let report = try await SpotFixture.check(h, url)
        #expect(report.outcome.skipReason == .unreadPatch, "was \(report.outcome.statLabel)")
        #expect(report.notes.contains(.unreadSpots))
        let spot = try #require(report.spots.first)
        #expect(report.spots.count == 1 && spot.state == .pending && spot.rect.intersects(TextLikePatchFixture.patch))
        let row = try #require(try await h.journal.uncheckedFiles().first)
        #expect(row.reason == .unreadPatch && row.spots == report.spots)
        #expect(try await h.journal.entries(matching: .all).isEmpty)
        #expect(try Data(contentsOf: url) == TextLikePatchFixture.data())
        let status = await h.engine.currentStatus()
        #expect(!status.problems.contains { $0.kind == .scanFailure } && status.problems.contains { $0.kind == .unreadSpots })
    }

    /// With "Cover spots Obscura can't read" on, the same photo ends covered: one cover, the padded band, and the count.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func withCoverOnThePhotoEndsCoveredWithThePaddedSpot() async throws {
        var settings = Settings.default
        settings.coversUnreadableSpots = true
        let h = try Harness(recognizer: VisionTextRecognizer(), settings: settings)
        defer { h.tearDown() }
        _ = try await VisionTextRecognizer().recognize(try TextLikePatchFixture.image(), options: OCROptions(timeout: .seconds(120)))
        let url = try Self.downloadsFile(h)
        let report = try await SpotFixture.check(h, url)
        guard case .redacted(let entryID, _, _) = report.outcome else { Issue.record("was \(report.outcome.statLabel)"); return }
        #expect(report.coveredSpots == 1 && report.notes.contains(.spotsCovered))
        let entry = try await h.journal.entry(entryID)
        let cover = try #require(entry.spotCovers.first)
        #expect(entry.findings.count == 1 && cover.enabled && cover.rect.contains(TextLikePatchFixture.patch))
        #expect(cover.rect == report.spots.first?.coverRect)
        #expect(try Data(contentsOf: url) != TextLikePatchFixture.data(), "the file holds the covered picture")
    }

    /// With "Skip spots too small to hold a secret" on, the photo still waits: 17 glyphs is not below 1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func withSkipOnThePhotoIsNotSkipped() async throws {
        var settings = Settings.default
        settings.skipsTinySpots = true
        let h = try Harness(recognizer: VisionTextRecognizer(), settings: settings)
        defer { h.tearDown() }
        _ = try await VisionTextRecognizer().recognize(try TextLikePatchFixture.image(), options: OCROptions(timeout: .seconds(120)))
        let report = try await SpotFixture.check(h, try Self.downloadsFile(h))
        #expect(report.outcome.skipReason == .unreadPatch && report.spots.map(\.state) == [.pending])
    }

    static func downloadsFile(_ h: Harness) throws -> URL {
        let folder = try Fixture.tempDirectory("text-like-patch")
        h.watch(folder, as: .downloads)
        let url = folder.appendingPathComponent("text-like-patch.png")
        try TextLikePatchFixture.data().write(to: url)
        return url
    }
}
