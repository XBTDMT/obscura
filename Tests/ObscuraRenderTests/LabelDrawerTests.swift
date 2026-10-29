import CoreGraphics
import Testing
@testable import ObscuraRender

@Suite struct LabelDrawerTests {
    @Test func contrastRule() {
        #expect(LabelDrawer.textColor(on: RGBA(r: 0.07, g: 0.07, b: 0.08)) == RGBA(r: 1, g: 1, b: 1, a: 0.85))
        #expect(LabelDrawer.textColor(on: RGBA(r: 0.95, g: 0.95, b: 0.95)) == RGBA(r: 0, g: 0, b: 0, a: 0.72))
        #expect(LabelDrawer.textColor(on: RGBA(r: 0.5, g: 0.5, b: 0.5)) == RGBA(r: 1, g: 1, b: 1, a: 0.85)) // ≤ 0.5 is "dark"
    }

    @Test func drawsWhiteOnDarkAndBlackOnLight() {
        for (fill, wantsBright) in [(RGBA(r: 0, g: 0, b: 0), true), (RGBA(r: 1, g: 1, b: 1), false)] {
            let image = TestImages.make(width: 200, height: 60) { ctx in
                ctx.setFillColor(fill.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 60))
                let drawn = LabelDrawer.draw("REDACTED", in: ctx, rect: CGRect(x: 0, y: 0, width: 200, height: 60), fill: fill)
                #expect(drawn == "REDACTED")
            }
            let p = TestImages.pixels(image)
            var changed = 0
            for y in 0..<60 { for x in 0..<200 {
                let v = Int(p.channels(x, y)[0])
                if wantsBright ? v > 150 : v < 110 { changed += 1 }
            } }
            #expect(changed > 100)
        }
    }

    @Test func skipsBelowSixPoints() {
        let image = TestImages.make(width: 200, height: 11) { ctx in
            ctx.setFillColor(RGBA(r: 1, g: 1, b: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 11))
            #expect(LabelDrawer.draw("REDACTED", in: ctx, rect: CGRect(x: 0, y: 0, width: 200, height: 11), fill: RGBA(r: 1, g: 1, b: 1)) == nil)
        }
        let p = TestImages.pixels(image)
        #expect(TestImages.differingPixels(p, TestImages.pixels(TestImages.flat(RGBA(r: 1, g: 1, b: 1), width: 200, height: 11))) == 0)
    }

    @Test func fallsBackToFirstWordThenNothing() {
        let ctx = CGContext(data: nil, width: 120, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: TestImages.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        #expect(LabelDrawer.draw("Key something very long", in: ctx, rect: CGRect(x: 0, y: 0, width: 120, height: 40), fill: RGBA(r: 1, g: 1, b: 1)) == "Key")
        #expect(LabelDrawer.draw("Supercalifragilistic", in: ctx, rect: CGRect(x: 0, y: 0, width: 40, height: 40), fill: RGBA(r: 1, g: 1, b: 1)) == nil)
    }
}
