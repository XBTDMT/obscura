import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ObscuraOCR

@Suite struct VisionSmokeTests {
    /// Real Vision run on a rendered image. Skipped under CI (no Vision models / ANE there). The token is made up.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func recognizesRenderedToken() async throws {
        let image = render("TOKEN=abc123xyz789", width: 700, height: 120)
        // The first .accurate request in a process loads Vision's models (12–25 s measured on 2026-10-26);
        // this test proves recognition, not latency, so it gets a generous budget.
        let lines = try await VisionTextRecognizer().recognize(image, options: OCROptions(timeout: .seconds(120)))
        #expect(lines.contains { $0.text.contains("abc123") })
        if let hit = lines.first(where: { $0.text.contains("abc123") }) {
            #expect(hit.rect.width > 100 && hit.rect.maxX <= 700 && hit.rect.maxY <= 120)
            let r = (hit.text as NSString).range(of: "abc123")
            let box = BoxMapper.rect(forUTF16Range: r, in: hit)
            #expect(box.width > 10 && hit.rect.insetBy(dx: -4, dy: -4).intersects(box))
        }
    }

    private func render(_ text: String, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 40, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let ctLine = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 30, y: 40)
        CTLineDraw(ctLine, ctx)
        return ctx.makeImage()!
    }
}
