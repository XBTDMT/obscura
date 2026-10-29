import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ObscuraRender

@Suite struct RedactorTests {
    /// The "secret": a dark text line that carries a pure-magenta glyph pattern. The ink colour is a mean of all
    /// text-ish pixels (grey + magenta), so a magenta pixel surviving anywhere inside the box means the original
    /// pixels leaked past the fill.
    static func secretImage() -> (CGImage, CGRect) {
        let rect = CGRect(x: 30, y: 20, width: 80, height: 16)
        let image = TestImages.make(width: 160, height: 60) { ctx in
            ctx.setFillColor(RGBA(r: 1, g: 1, b: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 60))
            ctx.setFillColor(RGBA(r: 0.1, g: 0.1, b: 0.1).cgColor)
            var x = 32
            while x < 106 { ctx.fill(CGRect(x: x, y: 24, width: 6, height: 8)); x += 10 }
            ctx.setFillColor(RGBA(r: 1, g: 0, b: 1).cgColor)
            ctx.fill(CGRect(x: 40, y: 22, width: 3, height: 12))
            ctx.fill(CGRect(x: 70, y: 22, width: 3, height: 12))
        }
        return (image, rect)
    }

    @Test(arguments: [StyleSpec.Kind.blur, .mosaic, .erase, .solid])
    func fillFirstLeavesNoOriginalPixelInsideAndNothingChangedOutside(kind: StyleSpec.Kind) throws {
        let (image, rect) = Self.secretImage()
        var style = StyleSpec.defaultStyle
        style.kind = kind
        let finding = PlacedFinding(rect: rect, textHeight: rect.height, label: "API key")
        let out = try Redactor.render(image, findings: [finding], style: style, environment: TestImages.env)
        let before = TestImages.pixels(image), after = TestImages.pixels(out)
        var magenta = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where TestImages.isMagentaish(after.channels(x, y)) { magenta += 1 }
        }
        #expect(magenta == 0)
        let padded = Redactor.paddedRect(for: finding, style: style, imageSize: CGSize(width: 160, height: 60))!
        #expect(TestImages.differingPixels(before, after, outside: padded) == 0)
        #expect(TestImages.differingPixels(before, after, inside: rect) > 0)
    }

    /// Two images whose secret pixels are the same multiset arranged differently must render byte-identically
    /// inside the box: the texture depends on geometry and two colours, never on the arrangement.
    @Test(arguments: [StyleSpec.Kind.blur, .mosaic])
    func textureIsIndependentOfSecretArrangement(kind: StyleSpec.Kind) throws {
        let rect = CGRect(x: 30, y: 20, width: 80, height: 16)
        func image(shift: Int) -> CGImage {
            TestImages.make(width: 160, height: 60) { ctx in
                ctx.setFillColor(RGBA(r: 1, g: 1, b: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 60))
                ctx.setFillColor(RGBA(r: 0.1, g: 0.1, b: 0.1).cgColor)
                var x = 34 + shift
                while x < 100 + shift { ctx.fill(CGRect(x: x, y: 24, width: 6, height: 8)); x += 10 }
            }
        }
        var style = StyleSpec.defaultStyle
        style.kind = kind
        let finding = PlacedFinding(rect: rect, textHeight: rect.height, label: "x")
        let a = try Redactor.render(image(shift: 0), findings: [finding], style: style, environment: TestImages.env)
        let b = try Redactor.render(image(shift: 4), findings: [finding], style: style, environment: TestImages.env)
        let padded = Redactor.paddedRect(for: finding, style: style, imageSize: CGSize(width: 160, height: 60))!
        #expect(TestImages.differingPixels(TestImages.pixels(a), TestImages.pixels(b), inside: padded) == 0)
    }

    @Test(arguments: [StyleSpec.Kind.blur, .mosaic])
    func textureIsDeterministicAndSaltChangesIt(kind: StyleSpec.Kind) throws {
        let (image, rect) = Self.secretImage()
        var style = StyleSpec.defaultStyle
        style.kind = kind
        let finding = PlacedFinding(rect: rect, textHeight: rect.height, label: "x")
        func png(salt: UInt64) throws -> Data {
            let env = RenderEnvironment(redactedWord: "REDACTED", seedSalt: salt)
            return try ImageCodec.encode(try Redactor.render(image, findings: [finding], style: style, environment: env), as: .png, dpi: nil, quality: nil)
        }
        #expect(try png(salt: 0) == png(salt: 0))
        #expect(try png(salt: 0) != png(salt: 7))
    }

    @Test func solidForcesOpaqueFill() throws {
        let image = TestImages.flat(RGBA(r: 1, g: 1, b: 1))
        var style = StyleSpec.defaultStyle
        style.color = RGBA(r: 0.2, g: 0.4, b: 0.6, a: 0.1)
        style.roundness = 0
        let rect = CGRect(x: 20, y: 20, width: 60, height: 20)
        let out = try Redactor.render(image, findings: [PlacedFinding(rect: rect, textHeight: 20, label: "x")], style: style, environment: TestImages.env)
        let c = TestImages.pixels(out).channels(50, 30)
        #expect(c[3] == 255)
        #expect(abs(Int(c[0]) - 51) <= 1 && abs(Int(c[1]) - 102) <= 1 && abs(Int(c[2]) - 153) <= 1)
    }

    @Test func roundnessChangesCorners() throws {
        let image = TestImages.flat(RGBA(r: 1, g: 1, b: 1))
        let rect = CGRect(x: 20, y: 10, width: 60, height: 30)
        var square = StyleSpec.defaultStyle, pill = StyleSpec.defaultStyle
        square.roundness = 0; pill.roundness = 1
        let finding = PlacedFinding(rect: rect, textHeight: 30, label: "x")
        let padded = Redactor.paddedRect(for: finding, style: square, imageSize: CGSize(width: 120, height: 60))!
        let a = TestImages.pixels(try Redactor.render(image, findings: [finding], style: square, environment: TestImages.env))
        let b = TestImages.pixels(try Redactor.render(image, findings: [finding], style: pill, environment: TestImages.env))
        let corner = (Int(padded.minX), Int(padded.minY))
        #expect(a.channels(corner.0, corner.1)[0] < 40)     // dark fill reaches the corner
        #expect(b.channels(corner.0, corner.1)[0] > 200)    // pill leaves the corner white
        #expect(a.channels(50, 25) == b.channels(50, 25))   // centre identical
    }

    @Test func paddingHasATwoPixelFloor() {
        var style = StyleSpec.defaultStyle
        style.padding = 0.14
        let tiny = PlacedFinding(rect: CGRect(x: 10, y: 10, width: 20, height: 5), textHeight: 5, label: "x")
        let padded = Redactor.paddedRect(for: tiny, style: style, imageSize: CGSize(width: 100, height: 100))!
        #expect(padded == CGRect(x: 8, y: 8, width: 24, height: 9))
        let tall = PlacedFinding(rect: CGRect(x: 10, y: 10, width: 100, height: 50), textHeight: 50, label: "x")
        let p2 = Redactor.paddedRect(for: tall, style: style, imageSize: CGSize(width: 400, height: 400))!
        #expect(p2.minX == 3)                         // padX = 7
        #expect(p2.minY == 3)                         // padY = min(0.16*50 = 8, 7) = 7
        let off = PlacedFinding(rect: CGRect(x: 500, y: 500, width: 10, height: 10), textHeight: 10, label: "x")
        #expect(Redactor.paddedRect(for: off, style: style, imageSize: CGSize(width: 100, height: 100)) == nil)
    }

    @Test func labelsAreDrawnForRedactedAndKindModes() throws {
        let image = TestImages.flat(RGBA(r: 1, g: 1, b: 1), width: 300, height: 80)
        let rect = CGRect(x: 10, y: 10, width: 280, height: 60)
        var none = StyleSpec.defaultStyle, redacted = StyleSpec.defaultStyle, kind = StyleSpec.defaultStyle
        none.roundness = 0; redacted.roundness = 0; kind.roundness = 0
        redacted.labelMode = .redacted; kind.labelMode = .kind
        let finding = PlacedFinding(rect: rect, textHeight: 60, label: "Password")
        let a = TestImages.pixels(try Redactor.render(image, findings: [finding], style: none, environment: TestImages.env))
        let b = TestImages.pixels(try Redactor.render(image, findings: [finding], style: redacted, environment: TestImages.env))
        let c = TestImages.pixels(try Redactor.render(image, findings: [finding], style: kind, environment: TestImages.env))
        #expect(TestImages.differingPixels(a, b, inside: rect) > 100)
        #expect(TestImages.differingPixels(a, c, inside: rect) > 100)
        #expect(TestImages.differingPixels(b, c, inside: rect) > 100)
    }

    @Test func styleSpecRoundTripsSnakeCase() throws {
        let data = try JSONEncoder().encode(StyleSpec.defaultStyle)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"label_mode\":\"none\""))
        #expect(text.contains("\"kind\":\"solid\""))
        #expect(try JSONDecoder().decode(StyleSpec.self, from: data) == StyleSpec.defaultStyle)
    }
}
