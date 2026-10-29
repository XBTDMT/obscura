public import CoreGraphics

/// splitmix64: a tiny, well-mixed PRNG so textures are reproducible from a seed alone.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in 0..<n.
    mutating func next(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// Draws made-up "text" — bars for blur, blocks for mosaic — from box geometry and two colours only.
/// Nothing here reads the source image; the secret's pixels, length and glyphs never reach this code.
public enum TextureSynth {
    /// Seed for a box, from its geometry and the caller's salt. Same box, same salt → same texture.
    public static func seed(for rect: CGRect, salt: UInt64) -> UInt64 {
        var mixer = SplitMix64(seed: salt ^ 0x6F62_7363_7572_6121) // "obscura!" tag, so salt 0 is not the raw state
        var acc: UInt64 = mixer.next()
        for v in [rect.minX, rect.minY, rect.width, rect.height] {
            let bits = UInt64(bitPattern: Int64(v.rounded()))
            acc = (acc ^ bits) &* 0x9E37_79B9_7F4A_7C15
            acc ^= mixer.next()
        }
        return acc
    }

    /// Draws the texture into `ctx` inside `rect` (context coordinates). Caller has already filled the background.
    public static func draw(in ctx: CGContext, rect: CGRect, textHeight: CGFloat, kind: StyleSpec.Kind, ink: RGBA, seed: UInt64) {
        guard kind == .blur || kind == .mosaic, rect.width >= 1, rect.height >= 1 else { return }
        var rng = SplitMix64(seed: seed)
        let textH = max(1, textHeight)
        let rows = max(1, Int(rect.height / textH))
        let rowPitch = rect.height / CGFloat(rows)
        let unit = 0.55 * textH
        let margin = min(unit, 0.08 * rect.width)
        let glyphH = 0.5 * textH

        ctx.saveGState()
        ctx.setFillColor(ink.cgColor)
        for row in 0..<rows {
            let centreY = rect.minY + rowPitch * (CGFloat(row) + 0.5)
            var x = rect.minX + margin
            while x < rect.maxX - unit {
                let units = 2 + rng.next(8) // 2…9 "letters"
                switch kind {
                case .blur:
                    let width = min(CGFloat(units) * unit, rect.maxX - x)
                    let bar = CGRect(x: x, y: centreY - glyphH / 2, width: width, height: glyphH)
                    let radius = min(glyphH / 3, width / 2)
                    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    ctx.fillPath()
                    x += width
                case .mosaic:
                    for _ in 0..<units {
                        guard x + 0.8 * unit <= rect.maxX else { break }
                        let h = textH * CGFloat(35 + rng.next(36)) / 100   // 35…70 % of text height
                        let alpha = Double(45 + rng.next(56)) / 100          // 0.45…1.0
                        ctx.setFillColor(ink.with(alpha: alpha).cgColor)
                        ctx.fill(CGRect(x: x, y: centreY - h / 2, width: 0.8 * unit, height: h))
                        x += unit
                    }
                    ctx.setFillColor(ink.cgColor)
                case .solid, .erase:
                    break
                }
                x += unit * CGFloat(1 + rng.next(2)) // word gap of 1 or 2 units
            }
        }
        ctx.restoreGState()
    }
}
