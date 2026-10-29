// MediaOutput: where the public README's pictures are written (docs/media/), and the window frame they are shown in.
//
// The media tests are off by default, so `swift test` stays fast and deterministic: they run only with
// OBSCURA_RENDER_MEDIA=1 (docs/media/README.md says how). Every picture is drawn by the app's own code from SampleData:
// made-up secrets only, never a capture of a real screen.
public import AppKit
public import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum MediaOutput {
    /// True only when OBSCURA_RENDER_MEDIA=1: the media tests are skipped otherwise.
    public static var enabled: Bool { ProcessInfo.processInfo.environment["OBSCURA_RENDER_MEDIA"] == "1" }

    /// `<repository>/docs/media`, found from this file's own place in the tree (Tests/ObscuraTestSupport/).
    public static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/media", isDirectory: true)
    }

    /// Writes `image` as an opaque sRGB PNG at `docs/media/<name>.png` and returns its URL. Opaque, because a picture on
    /// a README never needs alpha and a three-channel PNG is about a quarter smaller.
    @discardableResult
    public static func writePNG(_ image: CGImage, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        let opaque = flatten(image) ?? image
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // 144 dpi marks the picture as 2×, so a viewer that honours it shows it at its point size.
        CGImageDestinationAddImage(dest, opaque, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// The image drawn into an opaque sRGB context (no alpha channel).
    static func flatten(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: - The window frame

    /// The design system's desk (design/mockups/unified/system.html `--o-desk`), the backdrop every window sits on.
    public static func deskColours(dark: Bool) -> [CGColor] {
        dark ? [CGColor(srgbRed: 0x19 / 255, green: 0x21 / 255, blue: 0x2F / 255, alpha: 1),
                CGColor(srgbRed: 0x25 / 255, green: 0x1F / 255, blue: 0x34 / 255, alpha: 1),
                CGColor(srgbRed: 0x2E / 255, green: 0x24 / 255, blue: 0x20 / 255, alpha: 1)]
             : [CGColor(srgbRed: 0xD4 / 255, green: 0xE0 / 255, blue: 0xF1 / 255, alpha: 1),
                CGColor(srgbRed: 0xE2 / 255, green: 0xDE / 255, blue: 0xF0 / 255, alpha: 1),
                CGColor(srgbRed: 0xEF / 255, green: 0xE5 / 255, blue: 0xDD / 255, alpha: 1)]
    }

    /// Fills `rect` with the desk gradient.
    public static func fillDesk(_ ctx: CGContext, _ rect: CGRect, dark: Bool) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: deskColours(dark: dark) as CFArray,
                                  locations: [0, dark ? 0.52 : 0.5, 1])!
        ctx.saveGState()
        ctx.clip(to: rect)
        // Top to bottom rather than the design system's 150°: a vertical gradient keeps every PNG row one colour, which
        // compresses to almost nothing, where the diagonal made every pixel unique and doubled each file.
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    /// A window snapshot (ViewSnapshot, points × 2) placed on the desk with the window's rounded corners, hairline and
    /// shadow (`--o-shadow-win`), and macOS's three window buttons drawn at the top left, where a full-size-content window
    /// shows them. `chrome` is drawn over the window's top band before the buttons (the Viewer's toolbar, which is window
    /// chrome and so not in the content snapshot).
    public static func framedWindow(_ content: CGImage, pointSize: CGSize, dark: Bool, margin: CGFloat = 40,
                                    chrome: ((CGContext, CGRect) -> Void)? = nil) -> CGImage? {
        let scale: CGFloat = 2
        let size = CGSize(width: pointSize.width + 2 * margin, height: pointSize.height + 2 * margin)
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        fillDesk(ctx, CGRect(origin: .zero, size: size), dark: dark)
        let window = CGRect(x: margin, y: margin, width: pointSize.width, height: pointSize.height)
        let radius: CGFloat = 12
        let path = CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // Shadow: 0 20px 50px rgba(24,28,48,.22) and 0 3px 10px rgba(0,0,0,.08) (y-up, so the offset is negative).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 50,
                      color: dark ? CGColor(gray: 0, alpha: 0.55) : CGColor(srgbRed: 24 / 255, green: 28 / 255, blue: 48 / 255, alpha: 0.22))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: dark ? 0.14 : 0.96, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 10, color: CGColor(gray: 0, alpha: dark ? 0.3 : 0.08))
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(content, in: window)
        if let chrome {
            chrome(ctx, window)
        }
        drawWindowButtons(ctx, topLeft: CGPoint(x: window.minX + 20, y: window.maxY - 20))
        ctx.restoreGState()
        // The hairline: 0 0 0 .5px rgba(0,0,0,.12) light, rgba(255,255,255,.12) dark.
        ctx.addPath(CGPath(roundedRect: window.insetBy(dx: -0.25, dy: -0.25), cornerWidth: radius + 0.25, cornerHeight: radius + 0.25, transform: nil))
        ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// Close, minimise and zoom: 12 pt discs 20 pt apart, centred on `topLeft`'s row (y-up context).
    public static func drawWindowButtons(_ ctx: CGContext, topLeft: CGPoint) {
        let fills: [(CGFloat, CGFloat, CGFloat)] = [(0xFF, 0x5F, 0x57), (0xFE, 0xBC, 0x2E), (0x28, 0xC8, 0x40)]
        for (i, c) in fills.enumerated() {
            let disc = CGRect(x: topLeft.x + CGFloat(i) * 20 - 6, y: topLeft.y - 6, width: 12, height: 12)
            ctx.setFillColor(CGColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1))
            ctx.fillEllipse(in: disc)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
            ctx.setLineWidth(0.5)
            ctx.strokeEllipse(in: disc.insetBy(dx: 0.25, dy: 0.25))
        }
    }
}
