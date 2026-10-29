// MediaKit: the drawing, the real catch and the encoders behind the README and launch media (docs/media/, written only
// with OBSCURA_RENDER_MEDIA=1; docs/media/README.md says how to regenerate).
//
// Faithfulness rules: every picture of Obscura is drawn by Obscura's own code (SampleData's terminal, the engine's real
// covered output, MarkRenderer, ThumbnailView, CatchSearchItem's real title) from made-up secrets only. What is not
// Obscura's (the desk, a menu bar strip, a message window, Spotlight's panel, keycaps, captions) is drawn plainly here and
// called an illustration where it could be mistaken for a capture. No screen is ever captured.
//
// This target cannot see ObscuraTestSupport (its dependencies are fixed in Package.swift), so the few lines it shares
// with MediaOutput there (the desk colours, the PNG writer) are repeated here on purpose.
import AppKit
import AVFoundation
import CoreText
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ObscuraDetect
import ObscuraEngine
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSearch
import ObscuraSupport
import ObscuraUIKit
@testable import ObscuraThumbnailUI

enum Media {
    /// True only when OBSCURA_RENDER_MEDIA=1.
    static var enabled: Bool { ProcessInfo.processInfo.environment["OBSCURA_RENDER_MEDIA"] == "1" }

    /// The repository root, from this file's place in the tree (Tests/ObscuraThumbnailUITests/).
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var directory: URL { root.appendingPathComponent("docs/media", isDirectory: true) }

    static func url(_ relative: String) throws -> URL {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    // MARK: Colours (design/mockups/unified/system.html)

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let accent = rgb(0x5B5BD6)
    static let accentDark = rgb(0x8383E0)
    static let text = rgb(0x1D1D1F)
    static let text2 = rgb(0x3C3C43, 0.68)
    static let text3 = rgb(0x3C3C43, 0.45)
    static let ok = rgb(0x34C759)

    static func deskColours(dark: Bool) -> [CGColor] {
        dark ? [rgb(0x19212F), rgb(0x251F34), rgb(0x2E2420)] : [rgb(0xD4E0F1), rgb(0xE2DEF0), rgb(0xEFE5DD)]
    }

    // MARK: Contexts and images

    /// An sRGB context `size` points big at `scale` pixels per point, y up, already scaled.
    static func context(_ size: CGSize, scale: CGFloat) -> CGContext {
        let ctx = CGContext(data: nil, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        ctx.setShouldSmoothFonts(false)
        return ctx
    }

    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The app icon (Midnight + glass ring, chosen for the release 2026-10-28) at 512 px, the copy docs/media keeps for
    /// the README.
    static func appIcon() -> CGImage? {
        image(at: directory.appendingPathComponent("icon.png"))
    }

    /// Writes an opaque PNG (no alpha channel: about a quarter smaller) tagged 144 dpi when `retina`.
    static func writePNG(_ image: CGImage, to url: URL, retina: Bool = true) throws {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let opaque = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dpi = retina ? 144 : 72
        CGImageDestinationAddImage(dest, opaque, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A looping GIF from frames that each hold for their own delay (seconds), written with ImageIO.
    static func writeGIF(_ frames: [(image: CGImage, delay: Double)], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            let gif: [CFString: Any] = [kCGImagePropertyGIFDelayTime: frame.delay, kCGImagePropertyGIFUnclampedDelayTime: frame.delay]
            CGImageDestinationAddImage(dest, opaque(frame.image), [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func opaque(_ image: CGImage) -> CGImage {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// An H.264 MP4 (no audio) from frames drawn one by one with AVAssetWriter: `draw(i)` makes frame `i` at
    /// width × height pixels.
    @MainActor
    static func writeMP4(to url: URL, width: Int, height: Int, fps: Int, frames: Int, bitRate: Int,
                         draw: (Int) -> CGImage) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate, AVVideoMaxKeyFrameIntervalKey: fps * 2,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(draw(i), in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in writer.finishWriting { done.resume() } }
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Sets every pixel within `tolerance` levels of `colour` (each channel) to exactly `colour`, in place. The context
    /// must be an 8-bit RGBA one from `context(_:scale:)`, fully opaque where it matters.
    static func snap(_ ctx: CGContext, to colour: (UInt8, UInt8, UInt8), tolerance: Int) {
        guard let data = ctx.data else { return }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let target = [Int(colour.0), Int(colour.1), Int(colour.2)]
        for y in 0..<ctx.height {
            let row = bytes + y * ctx.bytesPerRow
            for x in 0..<ctx.width {
                let p = row + x * 4
                if abs(Int(p[0]) - target[0]) <= tolerance, abs(Int(p[1]) - target[1]) <= tolerance, abs(Int(p[2]) - target[2]) <= tolerance {
                    p[0] = colour.0; p[1] = colour.1; p[2] = colour.2
                }
            }
        }
    }

    // MARK: Easing (the same curves as the app's motion: OMotion's ease-out, the snap's overshoot)

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func easeOut(_ x: Double) -> Double { let x = clamp(x); return 1 - (1 - x) * (1 - x) * (1 - x) }
    static func easeInOut(_ x: Double) -> Double { let x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// 0 before `start`, rising to 1 over `length` seconds.
    static func ramp(_ t: Double, _ start: Double, _ length: Double) -> Double { clamp((t - start) / length) }
}

// MARK: - Drawing in top-left coordinates

/// A context of `size` points whose drawing calls take top-left rects, as the layout is thought of.
struct Canvas {
    let ctx: CGContext
    let size: CGSize

    init(size: CGSize, scale: CGFloat) {
        self.size = size
        ctx = Media.context(size, scale: scale)
    }

    func image() -> CGImage { ctx.makeImage()! }

    /// A y-up rect for a top-left one.
    func r(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: size.height - top - h, width: w, height: h)
    }

    func fill(_ color: CGColor, _ rect: CGRect? = nil) {
        ctx.setFillColor(color)
        ctx.fill(rect ?? CGRect(origin: .zero, size: size))
    }

    /// The desk gradient at 150°, over `rect` (the whole canvas by default).
    func desk(dark: Bool, _ rect: CGRect? = nil) {
        let rect = rect ?? CGRect(origin: .zero, size: size)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: Media.deskColours(dark: dark) as CFArray,
                                  locations: [0, 0.5, 1])!
        ctx.saveGState()
        ctx.clip(to: rect)
        // Top to bottom: a vertical gradient keeps every PNG row one colour, which compresses to almost nothing (the
        // design system's 150° diagonal made every pixel unique and doubled the files).
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil)
    }

    /// A rounded shape filled with `color`, with an optional drop shadow (`--o-shadow-win` style) and hairline.
    func panel(_ rect: CGRect, radius: CGFloat, color: CGColor, shadow: Bool = true, dark: Bool = false, hairline: Bool = true) {
        let path = roundedPath(rect, radius)
        if shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36,
                          color: dark ? CGColor(gray: 0, alpha: 0.5) : Media.rgb(0x181C30, 0.22))
            ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
        if hairline {
            ctx.addPath(path)
            ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.13) : CGColor(gray: 0, alpha: 0.12))
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }
    }

    /// `image` in `rect` with rounded corners, a shadow and a hairline, at `alpha`.
    func card(_ image: CGImage, _ rect: CGRect, radius: CGFloat, shadow: Bool = true, dark: Bool = false, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        panel(rect, radius: radius, color: Media.rgb(0x1E2430), shadow: shadow, dark: dark, hairline: false)
        ctx.saveGState()
        ctx.addPath(roundedPath(rect, radius)); ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        ctx.addPath(roundedPath(rect.insetBy(dx: 0.25, dy: 0.25), radius))
        ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.18))
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: Text

    enum Align { case left, center, right }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }

    static func line(_ s: String, font: CTFont, color: CGColor, kern: CGFloat = 0) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attributes[.kern] = kern }
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes))
    }

    static func width(_ s: String, font: CTFont, kern: CGFloat = 0) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(s, font: font, color: Media.text, kern: kern), nil, nil, nil))
    }

    /// One line of text whose baseline is `baseline` points from the top; truncated with "…" past `maxWidth`.
    @discardableResult
    func text(_ s: String, x: CGFloat, baseline: CGFloat, font: CTFont, color: CGColor, align: Align = .left,
              maxWidth: CGFloat? = nil, kern: CGFloat = 0) -> CGFloat {
        var line = Self.line(s, font: font, color: color, kern: kern)
        if let maxWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth {
            let ellipsis = Self.line("…", font: font, color: color)
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
        }
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let left: CGFloat = switch align { case .left: x; case .center: x - w / 2; case .right: x - w }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: left, y: size.height - baseline)
        CTLineDraw(line, ctx)
        return w
    }

    /// A keycap: a rounded light key with its symbol, as macOS draws key glyphs (an illustration, not a capture).
    func keycap(_ symbol: String, x: CGFloat, top: CGFloat, height: CGFloat, alpha: CGFloat = 1) -> CGFloat {
        let font = Self.font(height * 0.46, .medium)
        let w = max(height, Self.width(symbol, font: font) + height * 0.5)
        let rect = r(x, top, w, height)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 0, color: Media.rgb(0xB8B8C4))
        panel(rect, radius: height * 0.2, color: Media.rgb(0xFFFFFF), shadow: false, hairline: true)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: Media.rgb(0x181C30, 0.18))
        panel(rect, radius: height * 0.2, color: Media.rgb(0xFFFFFF), shadow: false, hairline: true)
        ctx.restoreGState()
        text(symbol, x: rect.midX, baseline: top + height * 0.66, font: font, color: Media.text, align: .center)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        return w
    }

    /// A row of keycaps starting at `x`; returns the row's width.
    @discardableResult
    func keys(_ symbols: [String], x: CGFloat, top: CGFloat, height: CGFloat, gap: CGFloat = 10, alpha: CGFloat = 1) -> CGFloat {
        var cursor = x
        for s in symbols { cursor += keycap(s, x: cursor, top: top, height: height, alpha: alpha) + gap }
        return cursor - gap - x
    }

    static func keysWidth(_ symbols: [String], height: CGFloat, gap: CGFloat = 10) -> CGFloat {
        let font = font(height * 0.46, .medium)
        return symbols.map { max(height, width($0, font: font) + height * 0.5) }.reduce(0, +) + gap * CGFloat(max(0, symbols.count - 1))
    }

    /// macOS's three window buttons, centred on the row `top + 6`.
    func windowButtons(x: CGFloat, top: CGFloat, diameter: CGFloat = 12, spacing: CGFloat = 20) {
        for (i, c) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            let disc = r(x + CGFloat(i) * spacing, top, diameter, diameter)
            ctx.setFillColor(Media.rgb(c)); ctx.fillEllipse(in: disc)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.14)); ctx.setLineWidth(0.5); ctx.strokeEllipse(in: disc.insetBy(dx: 0.25, dy: 0.25))
        }
    }
}

// MARK: - The catch, from the real engine

/// One cover of the engine's real output: the covered pixels of one finding (everything else transparent), and where
/// they sit in the image (pixels, top-left origin).
struct CoverPiece {
    let image: CGImage
    let rect: CGRect
}

/// SampleData's terminal screenshot (made-up keys), scanned by a real ShieldEngine (Vision OCR, the 84 detectors, the
/// recall pipeline, the renderer, the Journal) exactly as the app scans an imported image.
struct CaughtSample {
    static let displayName = "Screenshot 2026-10-28 at 9.41.12 AM.png"
    let displayName: String
    let original: CGImage
    let clean: CGImage
    let entry: Entry
    let titles: [String: String]
    let pieces: [CoverPiece]

    var pixelSize: CGSize { CGSize(width: original.width, height: original.height) }
    /// The terminal's point size (SampleData draws it at 2×).
    var pointSize: CGSize { CGSize(width: CGFloat(original.width) / 2, height: CGFloat(original.height) / 2) }

    @MainActor
    static func make(lines: [String] = SampleData.envLines, displayName: String = CaughtSample.displayName) async throws -> CaughtSample {
        let data = SampleData.terminalPNG(lines: lines, covered: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore())
        let engine = ShieldEngine(sources: [], recognizer: VisionTextRecognizer(), journal: journal, settings: InMemorySettingsStore(),
                                  clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil)
        _ = await engine.warmUp()
        let outcome = await engine.scan(imageData: data, source: .imported, displayName: displayName, filePath: nil, origin: nil)
        guard case .redacted(let entryID, _, _) = outcome else { throw MediaError.notCovered("\(outcome.statLabel)") }
        let entry = try await journal.entry(entryID)
        let cleanData = try await journal.cleanData(entryID)
        guard let original = Media.image(data), let clean = Media.image(cleanData) else { throw MediaError.notCovered("decode") }
        let titles = CoverLabels.titles(for: try Catalogue.resolved())
        let pieces = Self.coverPieces(original: original, clean: clean, findings: entry.findings.sorted { $0.lineIndex < $1.lineIndex })
        return CaughtSample(displayName: displayName, original: original, clean: clean, entry: entry, titles: titles, pieces: pieces)
    }

    /// Splits the engine's covers into one piece per finding: every pixel the clean image changed goes to the finding
    /// nearest it, so the animation snaps exactly the covers the engine drew, one after another.
    static func coverPieces(original: CGImage, clean: CGImage, findings: [ObscuraJournal.Finding]) -> [CoverPiece] {
        let w = original.width, h = original.height
        func rgba(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return bytes
        }
        let a = rgba(original), b = rgba(clean)
        var layers = findings.map { _ in [UInt8](repeating: 0, count: w * h * 4) }
        var boxes = findings.map { _ in CGRect.null }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let diff = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
                guard diff > 4 else { continue }
                // A bitmap context's first row in memory is the image's top row, so (x, y) is already top-left, as the
                // finding rects are.
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                var best = -1, bestDistance = CGFloat.infinity
                for (k, f) in findings.enumerated() {
                    let dx = max(f.rect.minX - p.x, 0, p.x - f.rect.maxX), dy = max(f.rect.minY - p.y, 0, p.y - f.rect.maxY)
                    let d = dx * dx + dy * dy
                    if d < bestDistance { bestDistance = d; best = k }
                }
                guard best >= 0, bestDistance < 40 * 40 else { continue }
                layers[best].replaceSubrange(i..<(i + 4), with: b[i..<(i + 4)])
                boxes[best] = boxes[best].union(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
            }
        }
        return zip(layers, boxes).compactMap { layer, box in
            guard !box.isNull else { return nil }
            var layer = layer
            let full: CGImage? = layer.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
            // `cropping(to:)` takes a top-left rect; `box` is already top-left.
            guard let crop = full?.cropping(to: box) else { return nil }
            return CoverPiece(image: crop, rect: box)
        }
    }

    /// The image drawn in `rect` (points, y-up) with the engine's covers at `t` seconds into the snap: before 0 none, then
    /// each piece snapping on (MarkTimeline's `.caught` timing, G-21: 0.18 s a piece, staggered), after it the clean image.
    func draw(on canvas: Canvas, in rect: CGRect, snapAt t: Double?, radius: CGFloat, shadow: Bool = true, dark: Bool = false,
              alpha: CGFloat = 1) {
        let n = pieces.count
        let finished = t.map { $0 >= MarkTimeline.duration(.caught, pieces: n) } ?? false
        canvas.card(finished ? clean : original, rect, radius: radius, shadow: shadow, dark: dark, alpha: alpha)
        guard let t, !finished, t > 0 else { return }
        let pose = MarkTimeline.pose(.caught, pieces: n, at: t)
        let k = rect.width / CGFloat(original.width)
        let ctx = canvas.ctx
        ctx.saveGState()
        ctx.addPath(canvas.roundedPath(rect, radius)); ctx.clip()
        for (i, piece) in pieces.enumerated() {
            let p = pose.pieces?[i] ?? MarkPiecePose(opacity: 1, scale: 1)
            guard p.opacity > 0.001 else { continue }
            let target = CGRect(x: rect.minX + piece.rect.minX * k, y: rect.maxY - piece.rect.maxY * k,
                                width: piece.rect.width * k, height: piece.rect.height * k)
            let s = CGFloat(p.scale)
            let scaled = CGRect(x: target.midX - target.width * s / 2, y: target.midY - target.height * s / 2,
                                width: target.width * s, height: target.height * s)
            ctx.setAlpha(CGFloat(p.opacity) * alpha)
            ctx.draw(piece.image, in: scaled)
        }
        ctx.restoreGState()
    }

    /// What Spotlight is given for this catch (CatchSearchItem, G-24): the title and description, labels only.
    func searchItem() -> SearchItemContent {
        var ids: [String] = [], categories: [String] = []
        for f in entry.findings.sorted(by: { $0.lineIndex < $1.lineIndex }) {
            for id in f.detectorIDs where !ids.contains(id) { ids.append(id) }
            if !categories.contains(f.category) { categories.append(f.category) }
        }
        let record = CoveredFileRecord(id: entry.id, filePath: "/Screenshots/\(displayName)", bookmark: nil, detectorIDs: ids,
                                       categories: categories, isScreenshot: true, caughtAt: entry.createdAt, updatedAt: entry.createdAt)
        return CatchSearchItem.build(record: record, titles: titles, thumbnail: nil)
    }
}

enum MediaError: Error { case notCovered(String) }

// MARK: - Obscura's own pieces as images

@MainActor
enum OwnPieces {
    /// Room drawn around the panel so the card's shadow fades out instead of stopping at the panel's edge.
    static let thumbnailBleed: CGFloat = 24

    /// The floating thumbnail card (ThumbnailView, design pick r3-a) over the covered image, at 2×: its panel
    /// (`panelSize` points) with `thumbnailBleed` around it.
    static func thumbnail(clean: CGImage, covered: Int) -> CGImage? {
        let content = ThumbnailContent(displayName: CaughtSample.displayName,
                                       image: NSImage(cgImage: clean, size: NSSize(width: clean.width / 2, height: clean.height / 2)),
                                       capsule: .covered(covered), hoverAction: .undo, hovering: false, edges: 0)
        let renderer = ImageRenderer(content: ThumbnailView(content: content).padding(thumbnailBleed).environment(\.colorScheme, .light))
        renderer.scale = 2
        var image: NSImage?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { image = renderer.nsImage }
        guard let image else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: 2))])
    }

    /// The rendered card's size in points, bleed included.
    static var thumbnailImageSize: CGSize {
        CGSize(width: ThumbnailPlacement.panelSize.width + 2 * thumbnailBleed, height: ThumbnailPlacement.panelSize.height + 2 * thumbnailBleed)
    }

    /// A menu bar mark frame at `scale` (MarkRenderer; the Classic ring through its NSImage, tinted as the bar tints a
    /// template image).
    static func mark(_ frame: MarkFrame, _ look: MarkLook, scale: CGFloat) -> CGImage? {
        if frame.mark == .classic {
            let ns = MenuBarMarkImage.image(frame, look, scales: [scale])
            var rect = CGRect(origin: .zero, size: ns.size)
            guard let raw = ns.cgImage(forProposedRect: &rect, context: nil,
                                       hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: scale))]) else { return nil }
            return ns.isTemplate ? tinted(raw, MarkPalette.ink(look.appearance)) : raw
        }
        guard let raw = MarkRenderer.render(frame, look, scale: scale) else { return nil }
        return MarkRenderer.isTemplate(frame, look) ? tinted(raw, MarkPalette.ink(look.appearance)) : raw
    }

    static func tinted(_ image: CGImage, _ ink: MarkRGBA) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: r)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(ink.cgColor)
        ctx.fill(r)
        return ctx.makeImage()
    }
}
