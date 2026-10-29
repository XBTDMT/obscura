public import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ObscuraSupport

public enum RedactorError: Error, Sendable, Equatable {
    case contextUnavailable
    case imageUnavailable
}

/// One shared Core Image context. CIContext is documented thread-safe; the box carries that promise to Swift.
final class SharedCIContext: @unchecked Sendable {
    static let shared = SharedCIContext()
    let context: CIContext
    private init() {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: true, // same bytes on every machine and every run; the inputs are box-sized
            .workingColorSpace: srgb,
            .outputColorSpace: srgb,
        ])
    }
}

/// Paints findings over an image. Security property: for every style the box is **filled first**,
/// so the pixels of the secret are gone before any texture, blur or pixellation runs on it.
public enum Redactor {
    /// Blur radius and pixellate scale as fractions of the text height, with floors in pixels.
    public static let blurRadiusFactor: CGFloat = 0.3, blurRadiusMinimum: CGFloat = 2
    public static let mosaicScaleFactor: CGFloat = 0.34, mosaicScaleMinimum: CGFloat = 4
    /// Vertical padding never exceeds this fraction of the text height, so boxes do not swallow neighbours.
    public static let verticalPaddingCap: CGFloat = 0.16
    public static let minimumPadding: CGFloat = 2

    /// Pads a finding rect for a style and clips it to the image. Nil when nothing (< 1 px) is left.
    public static func paddedRect(for finding: PlacedFinding, style: StyleSpec, imageSize: CGSize) -> CGRect? {
        let textH = max(1, finding.textHeight)
        let padX = max(minimumPadding, CGFloat(style.padding) * textH)
        let padY = max(minimumPadding, min(verticalPaddingCap * textH, padX))
        let bounds = CGRect(origin: .zero, size: imageSize)
        let padded = finding.rect.insetBy(dx: -padX, dy: -padY).intersection(bounds)
        guard !padded.isNull, padded.width >= 1, padded.height >= 1 else { return nil }
        // Snap outward to whole pixels: the texture bitmap is then exactly box-sized and the clip's
        // anti-aliasing stays inside the box, so every pixel outside it is untouched.
        // Round away float dust first (0.14 × 50 = 7.000000000000001) so it cannot cost a whole pixel.
        let q: CGFloat = 10_000
        let snapped = CGRect(x: (padded.minX * q).rounded() / q, y: (padded.minY * q).rounded() / q,
                             width: (padded.width * q).rounded() / q, height: (padded.height * q).rounded() / q)
        let integral = snapped.integral.intersection(bounds)
        guard !integral.isNull, integral.width >= 1, integral.height >= 1 else { return nil }
        return integral
    }

    public static func render(_ image: CGImage, findings: [PlacedFinding], style: StyleSpec, environment: RenderEnvironment) throws -> CGImage {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { throw RedactorError.imageUnavailable }
        let colorSpace: CGColorSpace
        if let own = image.colorSpace, own.model == .rgb { colorSpace = own } else { colorSpace = CGColorSpace(name: CGColorSpace.sRGB)! }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RedactorError.contextUnavailable
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let imageSize = CGSize(width: width, height: height)
        var painted = 0, skipped = 0
        for finding in findings {
            guard let padded = paddedRect(for: finding, style: style, imageSize: imageSize) else { skipped += 1; continue }
            let textH = max(1, finding.textHeight)
            // Findings are top-left origin; the context is bottom-left.
            let box = CGRect(x: padded.minX, y: CGFloat(height) - padded.maxY, width: padded.width, height: padded.height)
            let radius = CGFloat(min(max(style.roundness, 0), 1)) * min(box.width, box.height) / 2
            let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)

            // Sampling reads the ORIGINAL pixels, which is fine: it yields two colours, not geometry.
            let sample = style.kind == .solid ? nil : BackgroundSampler.sample(image, around: padded)

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            // 1. Fill. After this line no pixel of the secret exists in the context.
            let fillColor: RGBA
            if let sample {
                paintBackground(sample, in: ctx, box: box)
                fillColor = sample.representativeFill
            } else {
                fillColor = style.color.with(alpha: 1)
                ctx.setFillColor(fillColor.cgColor)
                ctx.fill(box)
            }
            // 2. Texture, built from geometry and the two sampled colours only.
            if let sample, style.kind == .blur || style.kind == .mosaic {
                let seed = TextureSynth.seed(for: padded, salt: environment.seedSalt)
                if let texture = makeTexture(size: padded.size, textHeight: textH, kind: style.kind, sample: sample, seed: seed) {
                    ctx.draw(texture, in: box)
                }
            }
            ctx.restoreGState()

            // 3. Label, outside the clip so a wide word is not cut by the rounded corners.
            let text: String?
            switch style.labelMode {
            case .none: text = nil
            case .redacted: text = environment.redactedWord
            case .kind: text = finding.label
            }
            if let text { LabelDrawer.draw(text, in: ctx, rect: box, fill: fillColor) }
            painted += 1
        }

        guard let result = ctx.makeImage() else { throw RedactorError.imageUnavailable }
        Log.render.info("rendered \(painted) findings, skipped \(skipped), style \(style.kind.rawValue, privacy: .public)")
        return result
    }

    /// Flat median, or a vertical linear gradient when the ring said the backdrop is not flat.
    static func paintBackground(_ sample: BackgroundSample, in ctx: CGContext, box: CGRect) {
        if let gradient = sample.gradient,
           let cg = CGGradient(colorsSpace: PixelBuffer.colorSpace,
                               colors: [gradient.top.cgColor, gradient.bottom.cgColor] as CFArray, locations: [0, 1]) {
            ctx.setFillColor(sample.background.cgColor)
            ctx.fill(box)
            ctx.drawLinearGradient(cg, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            ctx.setFillColor(sample.background.cgColor)
            ctx.fill(box)
        }
    }

    /// A box-sized sRGB bitmap: background, synthetic text, then the Core Image filter over `clampedToExtent()`.
    static func makeTexture(size: CGSize, textHeight: CGFloat, kind: StyleSpec.Kind, sample: BackgroundSample, seed: UInt64) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w >= 1, h >= 1,
              let tex = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: PixelBuffer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        paintBackground(sample, in: tex, box: rect)
        TextureSynth.draw(in: tex, rect: rect, textHeight: textHeight, kind: kind, ink: sample.ink, seed: seed)
        guard let base = tex.makeImage() else { return nil }

        let input = CIImage(cgImage: base)
        let filtered: CIImage
        switch kind {
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(max(blurRadiusMinimum, blurRadiusFactor * textHeight))
            filtered = filter.outputImage ?? input
        case .mosaic:
            let filter = CIFilter.pixellate()
            filter.inputImage = input.clampedToExtent()
            filter.scale = Float(max(mosaicScaleMinimum, mosaicScaleFactor * textHeight))
            filter.center = .zero
            filtered = filter.outputImage ?? input
        case .solid, .erase:
            return nil
        }
        return SharedCIContext.shared.context.createCGImage(filtered.cropped(to: input.extent), from: input.extent)
    }
}
