// obscura fixtures render — the per-detector PNG screenshot fixtures of DETECTORS.md §9.
// One PNG per built-in detector: the detector's first made-up positive from Tests/Fixtures/text/<id>.json, placed in a
// realistic context (terminal, .env file, JSON, log, editor) and drawn with CoreText in a fixed monospaced font at @2x.
// Each PNG has a sidecar <id>.json holding the drawn lines, the frame (font, size, colours) and the ground-truth findings
// (the Scanner run on the drawn text) with their ink boxes measured from the rendered pixels.
// Determinism: the same catalogue, text fixtures and macOS fonts give byte-identical PNGs (checked by `render --check`).
import AppKit
import ArgumentParser
import CoreGraphics
import CoreText
import Foundation
import ObscuraDetect
import ObscuraRender

// MARK: - Frames

/// A fixed look for one fixture image. Raw values are stored in the sidecar; never rename one.
enum FixtureFrame: String, Codable, CaseIterable, Sendable {
    case terminalDark = "terminal-dark"
    case envLight = "env-light"
    case jsonLight = "json-light"
    case jsonDark = "json-dark"
    case logLight = "log-light"
    case editorDark = "editor-dark"

    enum Font: String, Codable, Sendable {
        /// Menlo Regular, the Terminal default.
        case menlo
        /// The system monospaced face (SF Mono), as Xcode and most editors show it.
        case systemMono = "system-mono"
    }

    var font: Font {
        switch self {
        case .terminalDark, .jsonLight, .editorDark: .menlo
        case .envLight, .jsonDark, .logLight: .systemMono
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .terminalDark, .envLight: 13
        case .jsonLight, .editorDark: 14
        case .jsonDark, .logLight: 12
        }
    }

    var background: RGB8 {
        switch self {
        case .terminalDark: RGB8(30, 30, 30)
        case .envLight, .jsonLight: RGB8(255, 255, 255)
        case .jsonDark: RGB8(40, 42, 54)
        case .logLight: RGB8(250, 250, 250)
        case .editorDark: RGB8(31, 31, 36)
        }
    }

    var foreground: RGB8 {
        switch self {
        case .terminalDark: RGB8(229, 229, 229)
        case .envLight: RGB8(29, 29, 31)
        case .jsonLight: RGB8(36, 41, 47)
        case .jsonDark: RGB8(248, 248, 242)
        case .logLight: RGB8(40, 40, 40)
        case .editorDark: RGB8(212, 212, 212)
        }
    }

    /// Comment and banner lines are drawn dimmer, as the apps they imitate draw them.
    var dim: RGB8 {
        switch self {
        case .terminalDark: RGB8(150, 150, 155)
        case .envLight, .jsonLight, .logLight: RGB8(110, 110, 115)
        case .jsonDark: RGB8(160, 165, 190)
        case .editorDark: RGB8(120, 150, 110)
        }
    }

    /// Screenshot scale (Retina).
    static let scale: CGFloat = 2
    /// Left/right and top/bottom margins in points.
    static let marginX: CGFloat = 20, marginY: CGFloat = 16
    /// Line pitch as a multiple of the point size.
    static let pitchFactor: CGFloat = 1.5

    func ctFont() -> CTFont {
        let size = pointSize * Self.scale
        switch font {
        case .menlo: return CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        case .systemMono: return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        }
    }

    /// Lines for a bare token (no context of its own): the token is assigned to `variable`.
    func bareLines(variable: String, token: String) -> (lines: [String], secretLine: Int) {
        let prompt = "dev@workstation ~/projects/api %"
        switch self {
        case .terminalDark:
            return (["Last login: Mon Oct 27 09:12:44 on ttys002", "\(prompt) export \(variable)=\(token)", "\(prompt) npm run dev", "> node server.js"], 1)
        case .envLight:
            return (["# .env.local (development only)", "NODE_ENV=development", "\(variable)=\(token)", "LOG_LEVEL=debug", "PORT=8080"], 2)
        case .jsonLight, .jsonDark:
            return (["{", "  \"service\": \"billing-api\",", "  \"\(variable.lowercased())\": \"\(token)\",", "  \"region\": \"eu-west-1\"", "}"], 2)
        case .logLight:
            return (["2026-10-27 09:14:03 INFO  starting worker", "2026-10-27 09:14:03 DEBUG \(variable)=\(token)", "2026-10-27 09:14:04 INFO  worker ready"], 1)
        case .editorDark:
            return (["// settings.local, never commit", "\(variable) = \(token)", "// end of local settings"], 1)
        }
    }

    /// Lines for a positive that carries its own context (a label, a URL, a header), kept verbatim on its own line(s).
    func contextLines(_ body: [String]) -> (lines: [String], firstSecretLine: Int) {
        let prompt = "dev@workstation ~/projects/api %"
        switch self {
        case .terminalDark: return (["\(prompt) cat config/local.conf"] + body + ["\(prompt)"], 1)
        case .envLight: return (["# .env.local (development only)", "NODE_ENV=development"] + body + ["LOG_LEVEL=debug"], 2)
        case .logLight: return (["2026-10-27 09:14:03 INFO  loaded settings:"] + body + ["2026-10-27 09:14:04 INFO  worker ready"], 1)
        case .editorDark: return (["// settings.local, never commit"] + body + ["// end of local settings"], 1)
        case .jsonLight, .jsonDark: return (["{", "  \"service\": \"billing-api\","] + body + ["}"], 2)
        }
    }

    static let bareRotation: [FixtureFrame] = [.terminalDark, .envLight, .jsonLight, .jsonDark]
    static let contextRotation: [FixtureFrame] = [.terminalDark, .envLight, .logLight, .editorDark]
}

struct RGB8: Codable, Hashable, Sendable {
    let r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    var cgColor: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var luminance: Double { 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b) }
}

// MARK: - Sidecar

/// `Tests/Fixtures/images/<id>.json`. Field names are stable; the default test suite reads `detector`, `lines`, `expected`.
struct ImageSidecar: Codable, Sendable {
    struct Expected: Codable, Sendable, Hashable {
        /// Index into `lines`.
        let line: Int
        /// UTF-16 [location, length] of the secret in that line.
        let range: [Int]
        let wholeLine: Bool
        /// Every detector id the Scanner attributes to it (sorted).
        let detectors: [String]
        /// Ink bounding box of the secret's glyphs in image pixels, top-left origin: [x, y, width, height].
        let rect: [Int]
    }

    let detector: String
    let frame: FixtureFrame
    /// PostScript name of the font actually used, so a font change on a new macOS is visible in the diff.
    let fontName: String
    let pointSize: Double
    let scale: Double
    let width: Int
    let height: Int
    let lines: [String]
    let expected: [Expected]
}

// MARK: - Layout

/// Where every UTF-16 unit of every line sits. Shared by the generator and by `verify --images`, so the verifier knows
/// each glyph's cell without trusting OCR.
struct FixtureLayout {
    struct Line {
        let text: String
        let ctLine: CTLine
        /// Baseline, pixels from the top.
        let baseline: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        /// x of the leading edge of UTF-16 unit i, for i in 0...count (the last entry is the trailing edge).
        let unitX: [CGFloat]
        let dimmed: Bool

        /// Cell of UTF-16 unit `i` in pixels, top-left origin (full typographic height of the line).
        func cell(_ i: Int) -> CGRect {
            CGRect(x: unitX[i], y: baseline - ascent, width: unitX[i + 1] - unitX[i], height: ascent + descent)
        }
    }

    let frame: FixtureFrame
    let font: CTFont
    let width: Int
    let height: Int
    let lines: [Line]

    init(frame: FixtureFrame, lines texts: [String], dimmedLines: Set<Int>) {
        self.frame = frame
        let font = frame.ctFont()
        self.font = font
        let scale = FixtureFrame.scale
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let pitch = (frame.pointSize * FixtureFrame.pitchFactor * scale).rounded()
        let marginX = FixtureFrame.marginX * scale, marginY = FixtureFrame.marginY * scale
        var laid: [Line] = []
        var maxWidth: CGFloat = 0
        for (i, text) in texts.enumerated() {
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTLigatureAttributeName: 0,
                                          kCTForegroundColorAttributeName: (dimmedLines.contains(i) ? frame.dim : frame.foreground).cgColor]
            let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attributed)
            let count = text.utf16.count
            var xs: [CGFloat] = []
            xs.reserveCapacity(count + 1)
            for u in 0...count { xs.append(marginX + CTLineGetOffsetForStringIndex(line, u, nil)) }
            maxWidth = max(maxWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            let baseline = marginY + ascent + CGFloat(i) * pitch
            laid.append(Line(text: text, ctLine: line, baseline: baseline, ascent: ascent, descent: descent, unitX: xs, dimmed: dimmedLines.contains(i)))
        }
        self.lines = laid
        self.width = Int((marginX * 2 + maxWidth).rounded(.up))
        self.height = Int((marginY * 2 + ascent + descent + CGFloat(max(texts.count - 1, 0)) * pitch).rounded(.up))
    }

    /// Draws the frame: background, then every line with CoreText. Font smoothing off (macOS screenshots carry none).
    func render() throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw FixtureImageError.bitmap }
        ctx.setFillColor(frame.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldAntialias(true)
        for line in lines {
            // CoreGraphics is bottom-left; the layout is top-left.
            ctx.textPosition = CGPoint(x: line.unitX[0], y: CGFloat(height) - line.baseline)
            CTLineDraw(line.ctLine, ctx)
        }
        guard let image = ctx.makeImage() else { throw FixtureImageError.bitmap }
        return image
    }
}

enum FixtureImageError: Error, CustomStringConvertible {
    case bitmap
    case noFixture(String)
    case noComposition(String)

    var description: String {
        switch self {
        case .bitmap: "could not create the bitmap context"
        case .noFixture(let id): "\(id): no positive in Tests/Fixtures/text/\(id).json"
        case .noComposition(let id): "\(id): no frame yields findings for this detector alone; add a context to FixtureComposer"
        }
    }
}

// MARK: - Pixels

/// An RGBA8 copy of an image, top row first, for exact pixel comparisons.
struct RGBAPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard ok else { throw FixtureImageError.bitmap }
        bytes = buffer
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let o = (y * width + x) * 4
        return (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
    }

    /// A pixel is ink when its luminance is more than a quarter of full scale away from the background's.
    func isInk(_ x: Int, _ y: Int, background: RGB8) -> Bool {
        let (r, g, b) = rgb(x, y)
        let lum = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        return abs(lum - background.luminance) > 255 * 0.25
    }

    /// Integer pixel coordinates inside `rect`, clipped to the image.
    func pixels(in rect: CGRect) -> [(Int, Int)] {
        let x0 = max(0, Int(rect.minX.rounded(.down))), x1 = min(width, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY.rounded(.down))), y1 = min(height, Int(rect.maxY.rounded(.up)))
        guard x0 < x1, y0 < y1 else { return [] }
        var out: [(Int, Int)] = []
        out.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { for x in x0..<x1 { out.append((x, y)) } }
        return out
    }

    /// Ink pixels of UTF-16 unit `i` of `line`: inside the unit's cell and ink against the background.
    func inkPixels(unit i: Int, of line: FixtureLayout.Line, background: RGB8) -> [(Int, Int)] {
        pixels(in: line.cell(i)).filter { isInk($0.0, $0.1, background: background) }
    }
}

// MARK: - Composition

enum FixtureComposer {
    struct Composition {
        let frame: FixtureFrame
        let lines: [String]
        let dimmed: Set<Int>
        let findings: [Finding]
    }

    /// Variable name for a bare token, from the detector id (`ai.groq.apikey` → `GROQ_API_KEY`).
    static func variableName(for id: String) -> String {
        let parts = id.split(separator: ".").map(String.init)
        let special: [String: String] = [
            "databases.url.credentials": "DATABASE_URL", "databases.mongodb.atlas": "MONGODB_URI",
            "tokens.basicauth.url": "STATUS_URL", "tokens.jwt.compact": "SESSION_JWT",
            "cloud.gcp.oauthrefresh": "GOOGLE_REFRESH_TOKEN", "messaging.twilio.credentials": "TWILIO_ACCOUNT_SID",
        ]
        if let name = special[id] { return name }
        let kinds: [String: String] = [
            "apikey": "API_KEY", "accesskeyid": "ACCESS_KEY_ID", "secretkey": "SECRET_KEY", "sessiontoken": "SESSION_TOKEN",
            "clientsecret": "CLIENT_SECRET", "storagekey": "STORAGE_KEY", "apitoken": "API_TOKEN", "bottoken": "BOT_TOKEN",
            "webhooksecret": "WEBHOOK_SECRET", "webhook": "WEBHOOK_URL", "publishable": "PUBLISHABLE_KEY",
            "privatekey": "PRIVATE_KEY", "publickey": "PUBLIC_KEY", "serviceaccount": "SERVICE_ACCOUNT",
        ]
        let vendor = parts.count > 1 ? parts[1].uppercased() : "APP"
        let kind = parts.count > 2 ? (kinds[parts[2]] ?? parts[2].uppercased()) : "SECRET"
        return "\(vendor)_\(kind)"
    }

    /// A positive is bare when it is one token with no label of its own.
    static func isBare(_ positive: String) -> Bool {
        !positive.contains(where: \.isWhitespace) && !positive.contains("=")
    }

    /// Made-up base64 body lines for a block-scope sample, from a fixed seed (SplitMix64), so the PNG is reproducible.
    static func madeUpBase64Lines(seed: String, count: Int, width: Int = 64) -> [String] {
        var state: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 { state = (state ^ UInt64(byte)) &* 0x100000001b3 }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
        return (0..<count).map { _ in String((0..<width).map { _ in alphabet[Int(next() % 64)] }) }
    }

    struct Candidate {
        let frame: FixtureFrame
        let lines: [String]
        let dimmed: Set<Int>
        /// Lines that hold the sample; every ground-truth finding must sit on one of them.
        let secretLines: Set<Int>
    }

    /// Every composition tried for a detector, in preference order.
    static func candidates(for detector: Detector, positive: String, rotation index: Int) -> [Candidate] {
        var out: [Candidate] = []
        func dims(_ lines: [String]) -> Set<Int> {
            Set(lines.indices.filter { lines[$0].hasPrefix("#") || lines[$0].hasPrefix("//") || lines[$0].hasPrefix("Last login") })
        }
        func context(_ body: [String]) {
            for k in 0..<FixtureFrame.contextRotation.count {
                let frame = FixtureFrame.contextRotation[(index + k) % FixtureFrame.contextRotation.count]
                let (lines, first) = frame.contextLines(body)
                out.append(Candidate(frame: frame, lines: lines, dimmed: dims(lines), secretLines: Set(first..<(first + body.count))))
            }
        }
        if case .block = detector.scope {
            let footer = positive.replacingOccurrences(of: "BEGIN", with: "END")
            context([positive] + madeUpBase64Lines(seed: detector.id, count: 3) + [footer])
            return out
        }
        if isBare(positive) {
            let variable = variableName(for: detector.id)
            for k in 0..<FixtureFrame.bareRotation.count {
                let frame = FixtureFrame.bareRotation[(index + k) % FixtureFrame.bareRotation.count]
                let (lines, secretLine) = frame.bareLines(variable: variable, token: positive)
                out.append(Candidate(frame: frame, lines: lines, dimmed: dims(lines), secretLines: [secretLine]))
            }
        }
        context([positive])
        return out
    }

    /// The scanner configuration every image is judged under: the defaults, plus the detector under test switched on.
    static func scanner(for id: String) throws -> ObscuraDetect.Scanner {
        ObscuraDetect.Scanner(catalogue: try Catalogue.resolved(state: [id: true]))
    }

    /// First candidate whose ground truth is non-empty, sits only on the sample's lines and attributes every finding
    /// to the detector under test, so the context lines themselves trigger nothing.
    static func compose(_ detector: Detector, positive: String, rotation index: Int) throws -> Composition {
        let scanner = try scanner(for: detector.id)
        for c in candidates(for: detector, positive: positive, rotation: index) {
            let findings = scanner.scan(c.lines.enumerated().map { ScanLine(index: $0.offset, text: $0.element) })
            if !findings.isEmpty, findings.allSatisfy({ $0.detectorIDs.contains(detector.id) && c.secretLines.contains($0.lineIndex) }) {
                return Composition(frame: c.frame, lines: c.lines, dimmed: c.dimmed, findings: findings)
            }
        }
        throw FixtureImageError.noComposition(detector.id)
    }

    /// UTF-16 units a finding covers on its line.
    static func units(of finding: Finding, lineLength: Int) -> Range<Int> {
        if finding.wholeLine { return 0..<lineLength }
        return finding.secretRange.location..<(finding.secretRange.location + finding.secretRange.length)
    }

    /// Renders one detector's fixture. Returns the PNG bytes and the sidecar.
    static func make(_ detector: Detector, positive: String, rotation index: Int) throws -> (png: Data, sidecar: ImageSidecar) {
        let composition = try compose(detector, positive: positive, rotation: index)
        let layout = FixtureLayout(frame: composition.frame, lines: composition.lines, dimmedLines: composition.dimmed)
        let image = try layout.render()
        let pixels = try RGBAPixels(image)
        var expected: [ImageSidecar.Expected] = []
        for finding in composition.findings {
            let line = layout.lines[finding.lineIndex]
            var box = CGRect.null
            for u in units(of: finding, lineLength: line.text.utf16.count) {
                for (x, y) in pixels.inkPixels(unit: u, of: line, background: composition.frame.background) {
                    box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            expected.append(.init(line: finding.lineIndex, range: [finding.secretRange.location, finding.secretRange.length],
                                  wholeLine: finding.wholeLine, detectors: finding.detectorIDs.sorted(),
                                  rect: box.isNull ? [0, 0, 0, 0] : [Int(box.minX), Int(box.minY), Int(box.width), Int(box.height)]))
        }
        let png = try ImageCodec.encode(image, as: .png, dpi: CGSize(width: 72 * FixtureFrame.scale, height: 72 * FixtureFrame.scale), quality: nil)
        let sidecar = ImageSidecar(detector: detector.id, frame: composition.frame, fontName: CTFontCopyPostScriptName(layout.font) as String,
                                   pointSize: Double(composition.frame.pointSize), scale: Double(FixtureFrame.scale),
                                   width: layout.width, height: layout.height, lines: composition.lines, expected: expected)
        return (png, sidecar)
    }

    /// The layout a sidecar was drawn with (the verifier's ground truth for glyph cells).
    static func layout(for sidecar: ImageSidecar) -> FixtureLayout {
        let dims = Set(sidecar.lines.indices.filter { sidecar.lines[$0].hasPrefix("#") || sidecar.lines[$0].hasPrefix("//") || sidecar.lines[$0].hasPrefix("Last login") })
        return FixtureLayout(frame: sidecar.frame, lines: sidecar.lines, dimmedLines: dims)
    }
}

// MARK: - Command

extension Fixtures {
    struct Render: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Render Tests/Fixtures/images/<id>.png + <id>.json for every built-in detector from its first text-fixture positive.")
        @Option(name: .long, help: "Text fixture directory (default: Tests/Fixtures/text found from cwd or the binary).") var fixtures: String?
        @Option(name: .long, help: "Output directory (default: Tests/Fixtures/images next to the text fixtures).") var out: String?
        @Flag(name: .long, help: "Render in memory and compare with the checked-in files; exit 1 on any difference.") var check = false

        func run() throws {
            guard let textDir = fixtures.map({ URL(fileURLWithPath: $0, isDirectory: true) }) ?? CLI.fixturesDirectory() else {
                throw ValidationError("fixtures directory not found; pass --fixtures")
            }
            let outDir = out.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? textDir.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var written = 0, differing = 0
            for (index, detector) in Catalogue.builtIn.enumerated() {
                let file = textDir.appendingPathComponent("\(detector.id).json")
                guard let data = try? Data(contentsOf: file), let fixture = try? JSONDecoder().decode(Fixture.self, from: data),
                      let positive = fixture.positive.first else { throw FixtureImageError.noFixture(detector.id) }
                let (png, sidecar) = try FixtureComposer.make(detector, positive: positive, rotation: index)
                var json = try encoder.encode(sidecar)
                json.append(0x0A)
                let pngURL = outDir.appendingPathComponent("\(detector.id).png")
                let jsonURL = outDir.appendingPathComponent("\(detector.id).json")
                if check {
                    let same = (try? Data(contentsOf: pngURL)) == png && (try? Data(contentsOf: jsonURL)) == json
                    if !same { differing += 1; print("\(detector.id): differs from the checked-in fixture") }
                } else {
                    try png.write(to: pngURL, options: .atomic)
                    try json.write(to: jsonURL, options: .atomic)
                    written += 1
                }
                // Counts and frame only; the drawn text stays in the sidecar.
                print("\(detector.id.padding(toLength: 34, withPad: " ", startingAt: 0)) \(sidecar.frame.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(sidecar.width)x\(sidecar.height)  \(sidecar.expected.count) expected finding(s)")
            }
            if check {
                print("checked \(Catalogue.builtIn.count) fixtures, \(differing) differ")
                if differing > 0 { throw ExitCode(1) }
            } else {
                print("wrote \(written) PNG + sidecar pairs to \(outDir.path)")
            }
        }
    }
}
