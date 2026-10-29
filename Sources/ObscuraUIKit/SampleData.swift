// Invented sample content for previews, snapshot tests and the setup demo. Every value is made up and shaped so it
// fails the validators a real key would pass (EXAMPLE bodies, the 4242 test card, 555 phone numbers).
public import SwiftUI
import CoreText
public import ObscuraJournal
public import ObscuraPrefs
public import ObscuraSupport

public enum SampleData {
    /// Lines of the fake `.env` terminal used by the setup demo and the Redaction Style preview. The values are made up
    /// but shaped to each vendor's public format (the GitHub token carries a valid checksum), so the real detectors
    /// catch them: a demo built on obvious placeholders would show the app missing a Stripe key. They are the same
    /// generated values as the detector fixtures in Tests/Fixtures/text, and none is a real credential.
    public static let envLines: [String] = [
        "$ cat .env.production",
        "STRIPE_SECRET_KEY=sk_live_gHBJ59jWkyqhEGdgw5UhJjnc",
        "ANTHROPIC_API_KEY=sk-ant-api03-OdR-zLBztqrYi_rvGbv_a_Qx0nby3pkIrvS2pn9v7rZHTaTc8eH2yOynBcI5AA",
        "GITHUB_TOKEN=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",
        "DATABASE_URL=postgres://app:UJ3S7t8XofbcbG3y@db.example.internal:5432/app",
        "NODE_ENV=production",
        "PORT=3000",
    ]

    /// The secret lines of `envLines` and the detector that catches each, in badge order.
    public static let secretLines: [(line: Int, detectorID: String)] = [
        (1, "payments.stripe.secretkey"), (2, "ai.anthropic.apikey"), (3, "scm.github.token"), (4, "databases.url.credentials"),
    ]

    /// The one geometry of the sample terminal: `terminalPNG` draws its text and bars from it and `seed` takes its
    /// finding rects and pixel size from it, so a render always shows each bar exactly over its value.
    public struct TerminalLayout: Sendable {
        public let lines: [String]
        /// Width in points; the PNG is `scale` pixels per point.
        public let width: CGFloat
        public let scale: CGFloat
        /// Line pitch in points. The demo and previews use `defaultLineHeight`; a tighter pitch draws the line boxes of a
        /// dense editor, where Vision's boxes for neighbouring lines overlap (the engine's multi-line cover test).
        public let lineHeight: CGFloat
        public static let defaultLineHeight: CGFloat = 26, padding: CGFloat = 22, header: CGFloat = 28, fontSize: CGFloat = 15
        /// The bar runs from `barBelowBaseline` under the baseline up `barHeight`, around Menlo's descent and ascent, and
        /// `barTrailingPad` past the value's advance, because a final glyph's ink can overhang its advance.
        static let barBelowBaseline: CGFloat = 6, barHeight: CGFloat = 20, barRadius: CGFloat = 4, barTrailingPad: CGFloat = 1

        public init(lines: [String] = SampleData.envLines, width: Int = 960, scale: CGFloat = 2,
                    lineHeight: CGFloat = TerminalLayout.defaultLineHeight) {
            self.lines = lines
            self.width = CGFloat(width)
            self.scale = scale
            self.lineHeight = lineHeight
        }

        /// Height in points.
        public var height: CGFloat { Self.padding * 2 + lineHeight * CGFloat(lines.count) + Self.header }
        /// The PNG's size in pixels.
        public var pixelSize: CGSize { CGSize(width: (width * scale).rounded(.down), height: (height * scale).rounded(.down)) }

        var font: CTFont { CTFontCreateWithName("Menlo" as CFString, Self.fontSize, nil) }

        /// Line `i`'s baseline in drawing points (bottom-left origin).
        func baseline(_ i: Int) -> CGFloat {
            height - Self.padding - Self.header - lineHeight * CGFloat(i + 1) + 6
        }

        /// The bar over line `i`'s value (everything after the first `=`) in drawing points (bottom-left origin); nil
        /// when the line has no `=` or nothing after it. It starts where the value's first character starts, so no part
        /// of the value shows beside it.
        func barRect(line i: Int) -> CGRect? {
            guard lines.indices.contains(i), let eq = lines[i].firstIndex(of: "=") else { return nil }
            let line = lines[i]
            let start = Self.advance(String(line[...eq]), font: font)
            let full = Self.advance(line, font: font)
            guard full > start else { return nil }
            return CGRect(x: Self.padding + start, y: baseline(i) - Self.barBelowBaseline, width: full - start + Self.barTrailingPad,
                          height: Self.barHeight)
        }

        /// The bar over line `i`'s value in image pixels with a top-left origin: the rect a finding stores.
        public func valueRect(line i: Int) -> CGRect? {
            guard let r = barRect(line: i) else { return nil }
            return CGRect(x: r.minX * scale, y: (height - r.maxY) * scale, width: r.width * scale, height: r.height * scale)
        }

        static func advance(_ s: String, font: CTFont) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
    }

    /// Renders a small terminal screenshot. `covered` draws the redaction bars over the values of `secretLines`, except
    /// the lines in `leftVisible`.
    public static func terminalPNG(lines: [String] = envLines, covered: Bool, leftVisible: Set<Int> = [], width: Int = 960,
                                   scale: CGFloat = 2, lineHeight: CGFloat = TerminalLayout.defaultLineHeight) -> Data {
        let layout = TerminalLayout(lines: lines, width: width, scale: scale, lineHeight: lineHeight)
        let px = layout.pixelSize
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(red: 0x1E / 255, green: 0x24 / 255, blue: 0x30 / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        let font = layout.font
        let secret = Set(secretLines.map(\.line)).subtracting(leftVisible)
        for (i, line) in lines.enumerated() {
            let color = i == 0 ? CGColor(red: 0.56, green: 0.83, blue: 1, alpha: 1) : CGColor(red: 0.84, green: 0.86, blue: 0.9, alpha: 1)
            let attr = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: color])
            ctx.textPosition = CGPoint(x: TerminalLayout.padding, y: layout.baseline(i))
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            if covered, secret.contains(i), let rect = layout.barRect(line: i) {
                ctx.setFillColor(CGColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255, alpha: 1))
                let r = TerminalLayout.barRadius
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
                ctx.fillPath()
            }
        }
        guard let image = ctx.makeImage() else { return Data() }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// The findings `seed` stores for a sample terminal: one per `secretLines` entry, each rect the bar `terminalPNG`
    /// draws. `leftVisible` lists the badge indexes (0-based) stored as left visible.
    public static func terminalFindings(layout: TerminalLayout = TerminalLayout(), leftVisible: Set<Int> = []) -> [NewFinding] {
        secretLines.enumerated().compactMap { j, item in
            guard let rect = layout.valueRect(line: item.line) else { return nil }
            return NewFinding(lineIndex: item.line, rect: rect, detectorIDs: [item.detectorID],
                              category: String(item.detectorID.split(separator: ".").first ?? "tokens"),
                              enabled: !leftVisible.contains(j))
        }
    }

    /// A Journal in a temporary folder seeded with invented catches, for previews and tests.
    /// Its rule key lives in memory only (G-30), so previews and tests never touch the Keychain.
    public static func makeJournal(clock: any WallClock = SystemClock(), ruleKeys: any RuleKeyStore = InMemoryRuleKeyStore()) throws -> SQLiteJournalStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-sample-\(UUID().uuidString)")
        return try SQLiteJournalStore(root: root, ruleKeys: ruleKeys, clock: clock)
    }

    /// Seeds `journal` with `count` entries built from the sample terminal.
    public static func seed(_ journal: any JournalStore, count: Int = 6) async throws {
        let original = terminalPNG(covered: false), clean = terminalPNG(covered: true)
        // The second entry has its fourth finding left visible, so its clean image shows that value.
        let leftVisibleIndex = 3
        let partlyClean = terminalPNG(covered: true, leftVisible: [secretLines[leftVisibleIndex].line])
        let names = ["Screenshot 2026-10-26 at 9.41.12 AM.png", "Screenshot 2026-10-26 at 9.38.55 AM.png", "Clipboard image",
                     "Screenshot 2026-10-26 at 8.02.40 AM.png", "Imported · deploy-notes.png", "Screenshot 2026-10-25 at 6.17.03 PM.png"]
        let layout = TerminalLayout()
        for i in 0..<count {
            let findings = terminalFindings(layout: layout, leftVisible: i == 1 ? [leftVisibleIndex] : [])
            let source: EntrySource = i == 2 ? .clipboard : (i == 4 ? .imported : .file)
            _ = try await journal.create(NewEntry(source: source, displayName: names[i % names.count], containerUTI: "public.png",
                                                  pixelWidth: Int(layout.pixelSize.width), pixelHeight: Int(layout.pixelSize.height),
                                                  findings: findings),
                                         original: original, clean: i == 1 ? partlyClean : clean)
        }
    }

    /// A ready model on a seeded temporary Journal, with no engine (actions that need the engine are no-ops).
    @MainActor
    public static func model(entries count: Int = 6, settings: ObscuraPrefs.Settings = .default) async throws -> AppModel {
        let journal = try makeJournal()
        try await seed(journal, count: count)
        let model = AppModel(engine: nil, journal: journal, settings: InMemorySettingsStore(settings), router: RecordingRouter(), ownsRouter: true)
        model.start()
        await model.reloadEntries()
        return model
    }
}
