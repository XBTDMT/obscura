// ObscuraOCR — public value types and protocols. See README.md for the invariants.
public import Foundation
public import CoreGraphics

/// Answers "where on the image is this sub-range of the line's text?".
/// Coordinates are image pixels at FULL resolution, top-left origin, even when OCR ran on a downscaled copy.
/// Returns nil when the backing recognizer cannot answer (bad range, no geometry).
public protocol GlyphBoxProvider: Sendable {
    func boundingBox(forUTF16Range range: NSRange) -> CGRect?
    /// True when the provider answers each sub-range with that sub-range's own box (a stitched re-read keeps one box
    /// per UTF-16 unit). Vision's own provider answers any part of a word with the whole word's box, so it is false
    /// there and BoxMapper places the token inside the word by character offset instead.
    var isCharacterExact: Bool { get }
}

extension GlyphBoxProvider {
    public var isCharacterExact: Bool { false }
}

/// One recognized line of text. `rect` is in image pixels, top-left origin, full resolution.
/// `index` is the reading-order position after `LineOrdering.readingOrder`; before that it is the recognizer's order.
/// `glyphBoxes` are the ink boxes of single glyphs on this line's row (from text-rectangle detection, full resolution,
/// left to right); empty when the recognizer reports none. BoxMapper snaps covers to them.
/// `shortRead` is set when the line belongs to a re-read band whose reading stayed short of its ink (G-22): the engine
/// then covers every finding on it to the end of the line's ink.
/// Equality and hashing ignore `candidate`, `glyphBoxes` and `shortRead` (two lines with the same index, text and rect
/// are the same line).
public struct OCRLine: Sendable, Hashable {
    public var index: Int
    public let text: String
    public let rect: CGRect
    public let candidate: (any GlyphBoxProvider)?
    public var glyphBoxes: [CGRect]
    public var shortRead: ShortRead?

    public init(index: Int, text: String, rect: CGRect, candidate: (any GlyphBoxProvider)? = nil, glyphBoxes: [CGRect] = [],
                shortRead: ShortRead? = nil) {
        self.index = index
        self.text = text
        self.rect = rect
        self.candidate = candidate
        self.glyphBoxes = glyphBoxes
        self.shortRead = shortRead
    }

    public static func == (lhs: OCRLine, rhs: OCRLine) -> Bool {
        lhs.index == rhs.index && lhs.text == rhs.text && lhs.rect == rhs.rect
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(index)
        hasher.combine(text)
        hasher.combine(rect.origin.x); hasher.combine(rect.origin.y)
        hasher.combine(rect.size.width); hasher.combine(rect.size.height)
    }
}

/// Knobs for one recognition call. Defaults match ARCHITECTURE.md §4 rows 5–6.
public struct OCROptions: Sendable {
    public enum Level: Sendable { case accurate, fast }

    public var level: Level
    /// Off by default: correction rewrites tokens toward dictionary words and keys are not words.
    public var languageCorrection: Bool
    /// Per-image wall-clock budget; exceeding it throws `OCRError.timeout`.
    public var timeout: Duration
    /// Above this many pixels OCR runs on a downscaled copy; results are scaled back to full resolution.
    public var pixelBudget: Int
    /// Longest side of the downscaled copy.
    public var maxLongestSide: Int
    /// BCP-47 recognition languages; empty (the default) means the user's preferred languages that Vision supports plus
    /// English (`RecognitionLanguages`, G-31), so UI text in the user's languages around a secret still reads. Never
    /// Vision's automatic detection: it guessed a random token as Arabic and loaded that model on demand for 12–15 s
    /// inside an image's deadline. The G-12 re-read names a Latin-script language: it reads secret formats, which are
    /// ASCII, and auto-detection measured turning a trailing `",` into Vietnamese letters.
    public var languages: [String]

    public init(level: Level = .accurate,
                languageCorrection: Bool = false,
                timeout: Duration = .seconds(20),
                pixelBudget: Int = 24_000_000,
                maxLongestSide: Int = 4096,
                languages: [String] = []) {
        self.level = level
        self.languageCorrection = languageCorrection
        self.timeout = timeout
        self.pixelBudget = pixelBudget
        self.maxLongestSide = maxLongestSide
        self.languages = languages
    }
}

/// Every way a recognition can end other than with lines. No silent drops (ARCHITECTURE.md §3).
public enum OCRError: Error, Sendable {
    /// `OCROptions.timeout` elapsed before Vision answered.
    case timeout
    /// Vision or image preparation failed; the underlying error is kept for the log (never recognized text).
    case failed(underlying: any Error)
    /// The calling task was cancelled, or the queue evicted this request.
    case cancelled
    /// Zero-sized image, or the downscale bitmap could not be created.
    case badImage
    /// The `OCRQueue` was full and this (file) request was the oldest; the caller re-submits.
    case queueFull
}

/// Queue class. Clipboard images jump ahead of file images and are never evicted (a clipboard image not scanned is a leak path).
public enum OCRPriority: Sendable, Hashable {
    case clipboard
    case file
}

/// A region where text-rectangle detection found text: its box and the ink box of each glyph it found in it
/// (full resolution, top-left origin, left to right). Glyph boxes are ink, not advances: a narrow glyph is narrow,
/// and two touching glyphs can come back as one box.
public struct TextRegion: Sendable, Hashable {
    public let rect: CGRect
    public let glyphs: [CGRect]
    public init(rect: CGRect, glyphs: [CGRect] = []) {
        self.rect = rect
        self.glyphs = glyphs
    }
}

/// Everything one pass over an image found: the recognized lines and, when the recognizer can tell, where text is.
public struct OCRReading: Sendable {
    public var lines: [OCRLine]
    public var regions: [TextRegion]
    public init(lines: [OCRLine], regions: [TextRegion] = []) {
        self.lines = lines
        self.regions = regions
    }
}

public protocol TextRecognizer: Sendable {
    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine]
    /// Lines plus text regions. The default has no regions.
    func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading
    /// True when the recognizer reads the pixels it is given, so a crop of the image can be re-read (G-12 routes A, B).
    /// A stub that answers fixed lines whatever the image is cannot re-read anything; the default is false.
    var rereadsPixels: Bool { get }
}

extension TextRecognizer {
    public func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading {
        OCRReading(lines: try await recognize(image, options: options))
    }
    public var rereadsPixels: Bool { false }
}

/// Test and CI recognizer: returns the lines (and regions) it was given, ignoring the image.
public struct StubTextRecognizer: TextRecognizer {
    public let lines: [OCRLine]
    public let regions: [TextRegion]
    public init(lines: [OCRLine], regions: [TextRegion] = []) {
        self.lines = lines
        self.regions = regions
    }
    public func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] { lines }
    public func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading { OCRReading(lines: lines, regions: regions) }
}
