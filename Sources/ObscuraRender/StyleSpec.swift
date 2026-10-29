public import CoreGraphics
public import Foundation

/// A colour with straight (non-premultiplied) components in 0…1, sRGB.
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Relative luminance (WCAG coefficients) of the colour, alpha ignored.
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// The same colour with every component clamped to 0…1.
    public var clamped: RGBA {
        RGBA(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1), a: min(max(a, 0), 1))
    }

    public func with(alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    public var cgColor: CGColor {
        let c = clamped
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}

/// How a finding is covered. Persisted (snake_case) in the user's preferences and in Journal entries.
public struct StyleSpec: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case solid, erase, blur, mosaic
    }

    public enum LabelMode: String, Codable, Hashable, Sendable, CaseIterable {
        case none, redacted, kind
    }

    public var kind: Kind
    /// Fill colour for `.solid`; its alpha is ignored (always painted opaque).
    public var color: RGBA
    /// 0 = square corners, 1 = pill.
    public var roundness: Double
    /// Horizontal padding as a fraction of the finding's text height.
    public var padding: Double
    public var labelMode: LabelMode

    public init(kind: Kind, color: RGBA, roundness: Double, padding: Double, labelMode: LabelMode) {
        self.kind = kind
        self.color = color
        self.roundness = roundness
        self.padding = padding
        self.labelMode = labelMode
    }

    public static let defaultStyle = StyleSpec(
        kind: .solid,
        color: RGBA(r: 0.07, g: 0.07, b: 0.08, a: 1),
        roundness: 0.35,
        padding: 0.14,
        labelMode: .none
    )

    enum CodingKeys: String, CodingKey {
        case kind, color, roundness, padding
        case labelMode = "label_mode"
    }
}

/// A finding placed on the image: where to paint, how tall the text was, and what to call it.
public struct PlacedFinding: Sendable, Hashable {
    /// Image pixels, top-left origin.
    public var rect: CGRect
    public var textHeight: CGFloat
    /// The kind name printed when `labelMode == .kind` (already localized by the caller).
    public var label: String
    public var id: UUID

    public init(rect: CGRect, textHeight: CGFloat, label: String, id: UUID = UUID()) {
        self.rect = rect
        self.textHeight = textHeight
        self.label = label
        self.id = id
    }
}

/// Per-render inputs that are not style: localized strings and the texture salt.
public struct RenderEnvironment: Sendable {
    /// Localized "REDACTED", passed in so the package stays free of string tables.
    public var redactedWord: String
    /// Mixed into every texture seed. 0 by default; a caller that wants a fresh look on re-render changes it.
    public var seedSalt: UInt64

    public init(redactedWord: String, seedSalt: UInt64 = 0) {
        self.redactedWord = redactedWord
        self.seedSalt = seedSalt
    }
}
