import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ObscuraDetect
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraRender
import ObscuraSupport
import Testing
@testable import ObscuraEngine

// G-17: an uncovered key's text, read again from the original on demand. Every key here is made up (the engine
// fixtures' Stripe-shaped value, also a positive line in Tests/Fixtures/text).

/// A made-up `.env` line drawn in Menlo on white, and the pixel rect (top-left origin) of its value: what a catch stores.
enum KeyLineImage {
    static let label = "STRIPE_SECRET_KEY="
    static let fontSize: CGFloat = 30
    static let size = (width: 1400, height: 120)
    static let origin = CGPoint(x: 40, y: 45)   // baseline, bottom-left drawing coordinates

    static func png(key: String = Fixture.fakeKey) -> Data {
        let ctx = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        ctx.textPosition = origin
        CTLineDraw(line(label + key), ctx)
        return try! ImageCodec.encode(ctx.makeImage()!, as: .png, dpi: nil, quality: nil)
    }

    /// The value's box: from the end of the label to the end of the line, the font's ascent and descent tall.
    static func valueRect(key: String = Fixture.fakeKey) -> CGRect {
        let start = advance(label), end = advance(label + key)
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let top = CGFloat(size.height) - (origin.y + ascent)
        return CGRect(x: origin.x + start, y: top, width: end - start, height: ascent + descent).integral
    }

    private static func line(_ text: String) -> CTLine {
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)]
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!)
    }

    private static func advance(_ text: String) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line(text), nil, nil, nil)) }
}

/// Every file under `root` with a digest of its bytes, so a test can prove nothing was written.
func folderSnapshot(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return result }
    for case let url as URL in walker where (try url.resourceValues(forKeys: Set(keys))).isRegularFile == true {
        let data = try Data(contentsOf: url)
        result[String(url.path.dropFirst(root.path.count))] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return result
}

/// A Harness whose settings have the G-17 switch on (or off).
func keyTextHarness(recognizer: any TextRecognizer, switchOn: Bool = true) throws -> Harness {
    var settings = Settings.default
    settings.showsUncoveredKeyText = switchOn
    return try Harness(recognizer: recognizer, settings: settings)
}

/// Stores one entry with one finding over the made-up key's value, uncovered unless `covered`.
func storeKeyEntry(_ h: Harness, covered: Bool = false) async throws -> (entry: UUID, finding: UUID) {
    let png = KeyLineImage.png()
    let finding = NewFinding(lineIndex: 0, rect: KeyLineImage.valueRect(), detectorIDs: ["payments.stripe.secretkey"],
                             category: "payments", enabled: covered)
    let entry = try await h.journal.create(NewEntry(source: .file, displayName: "Key.png", containerUTI: "public.png",
                                                    pixelWidth: KeyLineImage.size.width, pixelHeight: KeyLineImage.size.height,
                                                    findings: [finding]),
                                           original: png, clean: png)
    return (entry.id, try #require(entry.findings.first).id)
}

@Suite struct KeyTextEngineTests {
    /// Real Vision on a made-up PNG: the uncovered finding reads back as the made-up key, and the Journal folder and
    /// database are byte-for-byte the same afterwards. Skipped under CI (no Vision models there).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func readsTheMadeUpKeyAndWritesNothing() async throws {
        let h = try keyTextHarness(recognizer: VisionTextRecognizer())
        defer { h.tearDown() }
        // Vision's first request loads its models (12–25 s cold); the read under test then runs warm.
        #expect(await h.engine.warmUp() != nil)
        let ids = try await storeKeyEntry(h)
        let before = try folderSnapshot(h.root)
        let statsBefore = try await h.journal.weekStats()
        let entryBefore = try await h.journal.entry(ids.entry)

        let text = try await h.engine.readText(of: ids.finding, in: ids.entry)
        #expect(text == Fixture.fakeKey, "read \(text.count) characters, not the made-up key")

        #expect(try folderSnapshot(h.root) == before, "the read wrote to the Journal folder or database")
        #expect(try await h.journal.weekStats() == statsBefore, "the read counted a stat")
        #expect(try await h.journal.entry(ids.entry) == entryBefore, "the read changed the entry")
    }

    @Test func unknownIDsThrowTheirOwnErrors() async throws {
        let h = try keyTextHarness(recognizer: StubTextRecognizer(lines: []))
        defer { h.tearDown() }
        let ids = try await storeKeyEntry(h)
        let missingEntry = UUID(), missingFinding = UUID()
        await #expect(throws: KeyTextError.entryNotFound(missingEntry)) { try await h.engine.readText(of: ids.finding, in: missingEntry) }
        await #expect(throws: KeyTextError.findingNotFound(missingFinding)) { try await h.engine.readText(of: missingFinding, in: ids.entry) }
    }

    @Test func refusesWhileTheSwitchIsOff() async throws {
        let h = try keyTextHarness(recognizer: StubTextRecognizer(lines: [Fixture.keyLine]), switchOn: false)
        defer { h.tearDown() }
        let ids = try await storeKeyEntry(h)
        await #expect(throws: KeyTextError.switchedOff) { try await h.engine.readText(of: ids.finding, in: ids.entry) }
        // Turned on, the same finding gets past the gate.
        h.settings.update { $0.showsUncoveredKeyText = true }
        await #expect(throws: KeyTextError.nothingRead) { try await h.engine.readText(of: ids.finding, in: ids.entry) }
    }

    @Test func refusesACoveredFinding() async throws {
        let h = try keyTextHarness(recognizer: StubTextRecognizer(lines: [Fixture.keyLine]))
        defer { h.tearDown() }
        let ids = try await storeKeyEntry(h, covered: true)
        await #expect(throws: KeyTextError.covered) { try await h.engine.readText(of: ids.finding, in: ids.entry) }
    }

    @Test func nothingReadIsAnError() async throws {
        let h = try keyTextHarness(recognizer: StubTextRecognizer(lines: []))
        defer { h.tearDown() }
        let ids = try await storeKeyEntry(h)
        let before = try folderSnapshot(h.root)
        await #expect(throws: KeyTextError.nothingRead) { try await h.engine.readText(of: ids.finding, in: ids.entry) }
        #expect(try folderSnapshot(h.root) == before)
    }

    @Test func aTimedOutReadSaysSo() async throws {
        let h = try keyTextHarness(recognizer: ScriptedRecognizer(error: .timeout))
        defer { h.tearDown() }
        let ids = try await storeKeyEntry(h)
        await #expect(throws: KeyTextError.timedOut) { try await h.engine.readText(of: ids.finding, in: ids.entry) }
    }

    @Test func aMissingOriginalIsUnavailable() async throws {
        let h = try keyTextHarness(recognizer: StubTextRecognizer(lines: []))
        defer { h.tearDown() }
        let ids = try await storeKeyEntry(h)
        try FileManager.default.removeItem(at: try await h.journal.originalURL(ids.entry))
        await #expect(throws: KeyTextError.originalUnavailable) { try await h.engine.readText(of: ids.finding, in: ids.entry) }
    }
}

@Suite struct KeyTextPickTests {
    static let scanner: ObscuraDetect.Scanner = {
        let catalogue = try! Catalogue.resolved()
        return ObscuraDetect.Scanner(catalogue: catalogue)
    }()

    /// A line laid out at a fixed 20 px advance, as a monospace re-read would be.
    static func line(_ text: String, y: CGFloat = 40) -> OCRLine {
        OCRLine(index: 0, text: text, rect: CGRect(x: 10, y: y, width: CGFloat((text as NSString).length) * 20, height: 36))
    }

    static func rect(of part: String, in line: OCRLine) -> CGRect {
        let r = (line.text as NSString).range(of: part)
        return CGRect(x: line.rect.minX + CGFloat(r.location) * 20, y: line.rect.minY, width: CGFloat(r.length) * 20, height: line.rect.height)
    }

    @Test func theDetectorsSecretPartWins() throws {
        let line = Self.line("STRIPE_SECRET_KEY=\(Fixture.fakeKey)")
        let pick = try #require(KeyText.pick(RecallReading(lines: [line]), image: nil, target: Self.rect(of: Fixture.fakeKey, in: line),
                                             detectorIDs: ["payments.stripe.secretkey"], scanner: Self.scanner))
        #expect(pick.text == Fixture.fakeKey)
        #expect(pick.detectorID != nil)
    }

    @Test func aKeyBesideTheTargetIsNotPicked() throws {
        // Two made-up keys on one row; the target is the second.
        let second = "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"
        let line = Self.line("a=\(Fixture.fakeKey) b=\(second)")
        let pick = try #require(KeyText.pick(RecallReading(lines: [line]), image: nil, target: Self.rect(of: second, in: line),
                                             detectorIDs: ["scm.github.token"], scanner: Self.scanner))
        #expect(pick.text == second)
    }

    @Test func withoutADetectorTheRawTokensInsideTheTargetAreKept() throws {
        let line = Self.line("note: made-up-value-0000 here")
        let pick = try #require(KeyText.pick(RecallReading(lines: [line]), image: nil, target: Self.rect(of: "made-up-value-0000", in: line),
                                             detectorIDs: ["generic.none"], scanner: Self.scanner))
        #expect(pick.text == "made-up-value-0000")
        #expect(pick.detectorID == nil)
    }

    @Test func nothingOnTheTargetIsNil() {
        let line = Self.line("plain words", y: 400)
        #expect(KeyText.pick(RecallReading(lines: [line]), image: nil, target: CGRect(x: 10, y: 40, width: 200, height: 36),
                             detectorIDs: [], scanner: Self.scanner) == nil)
    }

    @Test func theStripReadsContextAndIsClipped() throws {
        let rect = CGRect(x: 600, y: 50, width: 400, height: 24)
        let strip = try #require(KeyText.strip(around: rect, imageSize: CGSize(width: 1200, height: 90)))
        #expect(strip.tile.minX < rect.minX, "the label to the left is read too")
        #expect(strip.tile.maxX <= 1200 && strip.tile.minY >= 0 && strip.tile.maxY <= 90, "clipped to the image")
        #expect(strip.tile.contains(rect))
        #expect(strip.scale == 2, "a 24 px line is read at the recall pass's 48 px")
        let big = try #require(KeyText.strip(around: CGRect(x: 0, y: 0, width: 100, height: 80), imageSize: CGSize(width: 500, height: 500)))
        #expect(big.scale == 1, "never shrunk")
        #expect(KeyText.strip(around: CGRect(x: 900, y: 900, width: 10, height: 10), imageSize: CGSize(width: 100, height: 100)) == nil)
    }
}
