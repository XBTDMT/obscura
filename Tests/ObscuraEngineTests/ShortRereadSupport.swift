// G-22 test support: one long monospace line drawn as ink bars (so InkCells measures real pixels) and a scripted
// recognizer that answers each re-read sheet the way Vision did under load, deterministically. Every value is made up:
// the token is a fixed pseudo-random run, not a credential.
import CoreGraphics
import Foundation
@testable import ObscuraOCR

/// `aws_session_token = ` followed by a 302-character made-up token: the shape of the cloud.aws.sessiontoken fixture.
/// Glyph i occupies the cell x0 + i·advance; its ink is an 8×12 black bar inside the cell.
struct LongLineFixture {
    static let advance: CGFloat = 10, height: CGFloat = 20, x0: CGFloat = 40, y0: CGFloat = 10
    static let label = "aws_session_token = "

    let text: String
    let image: CGImage

    init(tokenLength: Int = 302) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/+")
        var state: UInt64 = 0x5EED_0B5C_0BA5_2026
        var token = ""
        for _ in 0..<tokenLength {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            token.append(alphabet[Int((state >> 33) % UInt64(alphabet.count))])
        }
        text = Self.label + token
        let units = Array(text.utf16)
        let width = Int(Self.x0 * 2 + CGFloat(units.count) * Self.advance), height = 40
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for i in units.indices where units[i] != 0x20 {
            let ink = Self.ink(i)
            ctx.fill(CGRect(x: ink.minX, y: CGFloat(height) - ink.maxY, width: ink.width, height: ink.height))
        }
        image = ctx.makeImage()!
    }

    var count: Int { text.utf16.count }
    var tokenRange: Range<Int> { Self.label.utf16.count..<count }

    /// The cell of glyph `i` (top-left origin) and the ink drawn in it.
    static func cell(_ i: Int) -> CGRect { CGRect(x: x0 + CGFloat(i) * advance, y: y0, width: advance, height: height) }
    static func ink(_ i: Int) -> CGRect { CGRect(x: x0 + CGFloat(i) * advance + 1, y: y0 + 4, width: 8, height: 12) }

    /// Pass 1 as Vision read the real fixture: one observation that stops early (after `readUnits` units), and a text
    /// region over the whole ink with one glyph box per glyph.
    func pass1(readUnits: Int = 112) -> OCRReading {
        let units = Array(text.utf16)
        let read = String(decoding: units[0..<readUnits], as: UTF16.self)
        let line = OCRLine(index: 0, text: read, rect: CGRect(x: Self.x0, y: Self.y0, width: CGFloat(readUnits) * Self.advance, height: Self.height),
                           candidate: CharacterBoxes(boxes: (0..<readUnits).map(Self.cell)))
        let glyphs = units.indices.filter { units[$0] != 0x20 }.map(Self.ink)
        let region = TextRegion(rect: CGRect(x: Self.x0, y: Self.y0, width: CGFloat(units.count) * Self.advance, height: Self.height), glyphs: glyphs)
        return OCRReading(lines: [line], regions: [region])
    }

    /// The strips the recall reader puts on its sheets for this line, in its order, as RecallReader computes them.
    func strips(tuning: RecallTuning = RecallTuning()) -> [RereadStrip] {
        let first = pass1()
        let lines = InkGlyphs.attach(first.lines, regions: first.regions)
        let bands = RereadPlanner.plan(lines: lines, regions: first.regions, imageSize: CGSize(width: image.width, height: image.height),
                                       labelLines: [], tuning: tuning)
        return bands.enumerated().flatMap { b, band in band.tiles.map { RereadStrip(band: b, tile: $0, scale: band.scale) } }
    }

    /// What a faithful reader of `strip` sees: the glyphs whose cells lie inside the tile, one observation, in sheet
    /// coordinates for `slot`. `keep` limits it to the first units (a fragment, as Vision returned under load).
    func observation(strip: RereadStrip, slot: CGRect, keep: Int? = nil) -> OCRLine? {
        let inside = (0..<count).filter { Self.cell($0).minX >= strip.tile.minX - 0.5 && Self.cell($0).maxX <= strip.tile.maxX + 0.5 }
        guard let lo = inside.first, var hi = inside.last.map({ $0 + 1 }) else { return nil }
        if let keep { hi = min(hi, lo + keep) }
        let units = Array(text.utf16)
        func toSheet(_ r: CGRect) -> CGRect {
            CGRect(x: slot.minX + (r.minX - strip.tile.minX) * strip.scale, y: slot.minY + (r.minY - strip.tile.minY) * strip.scale,
                   width: r.width * strip.scale, height: r.height * strip.scale)
        }
        let boxes = (lo..<hi).map { toSheet(Self.cell($0)) }
        return OCRLine(index: 0, text: String(decoding: units[lo..<hi], as: UTF16.self), rect: boxes.reduce(CGRect.null) { $0.union($1) },
                       candidate: CharacterBoxes(boxes: boxes))
    }
}

/// Counts sheet requests.
actor SheetCalls {
    private(set) var count = 0
    func next() -> Int { defer { count += 1 }; return count }
}

/// Answers pass 1 with the fixture's early-stopping reading and every re-read sheet from `script`: for sheet request
/// `call`, the strips on it (in the reader's order, scaled for that attempt) and how many units of each to return
/// (nil = the strip's whole reading, 0 = nothing).
struct ShortSheetRecognizer: TextRecognizer {
    let fixture: LongLineFixture
    /// Per sheet request: the strips laid out on it, in order, and per strip the units kept (nil = all).
    let script: @Sendable (_ call: Int) -> [(strip: RereadStrip, keep: Int?)]
    let calls = SheetCalls()
    let tuning = RecallTuning()

    var rereadsPixels: Bool { true }

    func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading { fixture.pass1() }

    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        let call = await calls.next()
        let strips = script(call)
        guard let layout = RereadSheet.layout(strips.map(\.strip), maxSide: tuning.sheetMaxSide).first else { return [] }
        return layout.slots.compactMap { slot in
            let (strip, keep) = strips[slot.strip]
            if keep == 0 { return nil }
            return fixture.observation(strip: strip, slot: slot.rect, keep: keep)
        }
    }
}
