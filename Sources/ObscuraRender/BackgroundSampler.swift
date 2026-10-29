public import CoreGraphics

/// What the renderer learned about the pixels around a finding.
public struct BackgroundSample: Sendable {
    /// Per-channel median of the ring around the padded rect: the colour a flat erase paints.
    public var background: RGBA
    /// Mean of the inside pixels that differ from the background: the colour synthetic texture is drawn in.
    public var ink: RGBA
    /// True when the ring's variance says the backdrop is not flat (gradient, photo).
    public var isGradient: Bool
    /// Least-squares linear fit of the ring colour against y, evaluated at the top and bottom edges
    /// of the padded rect. Present only when `isGradient`.
    public var gradient: (top: RGBA, bottom: RGBA)?

    public init(background: RGBA, ink: RGBA, isGradient: Bool, gradient: (top: RGBA, bottom: RGBA)?) {
        self.background = background
        self.ink = ink
        self.isGradient = isGradient
        self.gradient = gradient
    }

    /// The flat colour a label's contrast rule should judge against.
    public var representativeFill: RGBA {
        guard let gradient else { return background }
        return RGBA(r: (gradient.top.r + gradient.bottom.r) / 2,
                    g: (gradient.top.g + gradient.bottom.g) / 2,
                    b: (gradient.top.b + gradient.bottom.b) / 2, a: 1)
    }
}

public enum BackgroundSampler {
    /// Colours used when the window is empty or cannot be read.
    public static let fallbackBackground = RGBA(r: 0.07, g: 0.07, b: 0.08, a: 1)
    public static let fallbackInk = RGBA(r: 0.85, g: 0.85, b: 0.85, a: 1)
    /// L1 distance (sum of |dR|+|dG|+|dB|) from the median above which an inside pixel counts as ink.
    public static let inkThreshold = 0.45
    /// Mean per-channel variance of the ring above which the backdrop is treated as a gradient.
    /// 0.0004 is a standard deviation of ~5/255: anti-aliasing noise on a flat screenshot stays below it.
    public static let gradientVarianceThreshold = 0.0004

    /// Samples a `ring`-pixel band around `rect` (image pixels, top-left origin) and the pixels inside it.
    public static func sample(_ image: CGImage, around rect: CGRect, ring: Int = 3) -> BackgroundSample {
        let fallback = BackgroundSample(background: fallbackBackground, ink: fallbackInk, isGradient: false, gradient: nil)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let window = rect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring)).intersection(bounds).integral
        guard !window.isNull, window.width >= 1, window.height >= 1,
              let pixels = PixelBuffer(image: image, crop: window) else { return fallback }

        let inner = rect.offsetBy(dx: -window.minX, dy: -window.minY)
        var ringR: [Double] = [], ringG: [Double] = [], ringB: [Double] = [], ringY: [Double] = []
        var inside: [RGBA] = []
        ringR.reserveCapacity(pixels.width * pixels.height)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let c = pixels.rgba(x, y)
                if inner.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    inside.append(c)
                } else {
                    ringR.append(c.r); ringG.append(c.g); ringB.append(c.b)
                    ringY.append(Double(y) + 0.5 + window.minY)
                }
            }
        }
        if ringR.isEmpty {
            // The box touches every image edge: judge by the inside instead so there is still a colour.
            for c in inside { ringR.append(c.r); ringG.append(c.g); ringB.append(c.b) }
            ringY = []
        }
        guard !ringR.isEmpty else { return fallback }

        let background = RGBA(r: median(ringR), g: median(ringG), b: median(ringB), a: 1)

        var inkSum = (r: 0.0, g: 0.0, b: 0.0), inkCount = 0
        for c in inside where abs(c.r - background.r) + abs(c.g - background.g) + abs(c.b - background.b) > inkThreshold {
            inkSum.r += c.r; inkSum.g += c.g; inkSum.b += c.b; inkCount += 1
        }
        let ink: RGBA
        if inkCount > 0 {
            let n = Double(inkCount)
            ink = RGBA(r: inkSum.r / n, g: inkSum.g / n, b: inkSum.b / n, a: 1)
        } else {
            let grey = background.luminance < 0.5 ? 0.85 : 0.2
            ink = RGBA(r: grey, g: grey, b: grey, a: 1)
        }

        let varianceMean = (variance(ringR) + variance(ringG) + variance(ringB)) / 3
        var gradient: (top: RGBA, bottom: RGBA)? = nil
        if varianceMean > gradientVarianceThreshold, ringY.count >= 2, let fit = linearFit(ringY, ringR, ringG, ringB) {
            let top = RGBA(r: fit.r.at(rect.minY), g: fit.g.at(rect.minY), b: fit.b.at(rect.minY), a: 1).clamped
            let bottom = RGBA(r: fit.r.at(rect.maxY), g: fit.g.at(rect.maxY), b: fit.b.at(rect.maxY), a: 1).clamped
            gradient = (top, bottom)
        }
        return BackgroundSample(background: background, ink: ink, isGradient: gradient != nil, gradient: gradient)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    struct Line { var slope: Double; var intercept: Double; func at(_ y: Double) -> Double { slope * y + intercept } }

    /// Ordinary least squares of each channel against y; nil when every y is the same.
    static func linearFit(_ ys: [Double], _ r: [Double], _ g: [Double], _ b: [Double]) -> (r: Line, g: Line, b: Line)? {
        let n = Double(ys.count)
        let meanY = ys.reduce(0, +) / n
        let sxx = ys.reduce(0) { $0 + ($1 - meanY) * ($1 - meanY) }
        guard sxx > 0 else { return nil }
        func fit(_ v: [Double]) -> Line {
            let meanV = v.reduce(0, +) / n
            var sxy = 0.0
            for i in 0..<v.count { sxy += (ys[i] - meanY) * (v[i] - meanV) }
            let slope = sxy / sxx
            return Line(slope: slope, intercept: meanV - slope * meanY)
        }
        return (fit(r), fit(g), fit(b))
    }
}
