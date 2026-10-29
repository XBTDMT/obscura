public import CoreGraphics
import CoreText
import Foundation

/// Prints a word centred on a box with CoreText, in a colour that contrasts with the fill.
public enum LabelDrawer {
    public static let minimumFontSize: CGFloat = 6
    public static let maximumFontSize: CGFloat = 72

    /// White at 0.85 on dark fills (luminance ≤ 0.5), black at 0.72 on light ones.
    public static func textColor(on fill: RGBA) -> RGBA {
        fill.luminance <= 0.5 ? RGBA(r: 1, g: 1, b: 1, a: 0.85) : RGBA(r: 0, g: 0, b: 0, a: 0.72)
    }

    public static func fontSize(forBoxHeight h: CGFloat) -> CGFloat { min(maximumFontSize, 0.5 * h) }

    /// Draws `text` centred in `rect` (context coordinates, unflipped). Returns the string actually drawn,
    /// nil when the font would be below 6 pt or nothing fits. A text that is too wide falls back to its
    /// first word, then to nothing.
    @discardableResult
    public static func draw(_ text: String, in ctx: CGContext, rect: CGRect, fill: RGBA) -> String? {
        let size = fontSize(forBoxHeight: rect.height)
        guard size >= minimumFontSize else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let color = textColor(on: fill).cgColor
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let maxWidth = rect.width - 0.8 * size

        var candidates = [trimmed]
        if let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first, first.count < trimmed.count {
            candidates.append(String(first))
        }
        for candidate in candidates {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: candidate, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            guard bounds.width <= maxWidth else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                                       y: rect.midY - bounds.height / 2 - bounds.minY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            return candidate
        }
        return nil
    }
}
