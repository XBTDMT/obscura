import CoreGraphics
import Testing
@testable import ObscuraRender

@Suite struct BackgroundSamplerTests {
    @Test func flatImageReturnsItsColour() {
        let image = TestImages.flat(RGBA(r: 0.2, g: 0.5, b: 0.8))
        let s = BackgroundSampler.sample(image, around: CGRect(x: 20, y: 20, width: 40, height: 20))
        #expect(abs(s.background.r - 0.2) < 0.01 && abs(s.background.g - 0.5) < 0.01 && abs(s.background.b - 0.8) < 0.01)
        #expect(!s.isGradient && s.gradient == nil)
        #expect(abs(s.ink.r - 0.85) < 0.001) // nothing inside differs: dark background → light grey ink
    }

    @Test func inkIsTheMeanOfPixelsFarFromTheMedian() {
        let image = TestImages.make(width: 100, height: 40) { ctx in
            ctx.setFillColor(RGBA(r: 1, g: 1, b: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
            ctx.setFillColor(RGBA(r: 0, g: 0, b: 0.5).cgColor); ctx.fill(CGRect(x: 30, y: 15, width: 40, height: 10))
        }
        let s = BackgroundSampler.sample(image, around: CGRect(x: 20, y: 10, width: 60, height: 20))
        #expect(s.background.r > 0.99)
        #expect(s.ink.r < 0.01 && abs(s.ink.b - 0.5) < 0.01)
    }

    @Test func verticalGradientIsDetectedAndFitsBetterThanFlat() {
        let height = 80
        func rowColor(_ y: Int) -> RGBA { let t = Double(y) / Double(height - 1); return RGBA(r: 0.1 + 0.8 * t, g: 0.5, b: 0.9 - 0.8 * t) }
        let image = TestImages.make(width: 100, height: height) { ctx in
            for y in 0..<height { ctx.setFillColor(rowColor(y).cgColor); ctx.fill(CGRect(x: 0, y: y, width: 100, height: 1)) }
        }
        let rect = CGRect(x: 20, y: 10, width: 60, height: 50)
        let s = BackgroundSampler.sample(image, around: rect)
        #expect(s.isGradient)
        let g = try! #require(s.gradient)
        var flatErr = 0.0, gradErr = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let truth = rowColor(y)
            let t = (Double(y) + 0.5 - rect.minY) / rect.height
            let fit = RGBA(r: g.top.r + (g.bottom.r - g.top.r) * t, g: g.top.g + (g.bottom.g - g.top.g) * t, b: g.top.b + (g.bottom.b - g.top.b) * t)
            flatErr += abs(truth.r - s.background.r) + abs(truth.g - s.background.g) + abs(truth.b - s.background.b)
            gradErr += abs(truth.r - fit.r) + abs(truth.g - fit.g) + abs(truth.b - fit.b)
        }
        #expect(gradErr < flatErr / 5)
    }

    @Test func eraseOnGradientBeatsFlat() throws {
        let image = TestImages.page()
        let rect = CGRect(x: 240, y: 50, width: 60, height: 40)   // inside the gradient band
        var style = StyleSpec.defaultStyle
        style.kind = .erase; style.roundness = 0
        let out = TestImages.pixels(try Redactor.render(image, findings: [PlacedFinding(rect: rect, textHeight: 16, label: "x")], style: style, environment: TestImages.env))
        let src = TestImages.pixels(image)
        let flat = BackgroundSampler.sample(image, around: rect).background
        var gradErr = 0, flatErr = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let truth = src.channels(x, y), got = out.channels(x, y)
                for c in 0..<3 {
                    gradErr += abs(Int(truth[c]) - Int(got[c]))
                    flatErr += abs(Int(truth[c]) - Int((flat.clamped.r * 255).rounded()) * (c == 0 ? 1 : 0) - (c == 1 ? Int((flat.g * 255).rounded()) : 0) - (c == 2 ? Int((flat.b * 255).rounded()) : 0))
                }
            }
        }
        #expect(gradErr < flatErr / 3)
    }

    @Test func boxCoveringTheWholeImageStillYieldsAColour() {
        let image = TestImages.flat(RGBA(r: 0.3, g: 0.3, b: 0.3))
        let s = BackgroundSampler.sample(image, around: CGRect(x: 0, y: 0, width: 120, height: 60))
        #expect(abs(s.background.r - 0.3) < 0.01)
    }
}
