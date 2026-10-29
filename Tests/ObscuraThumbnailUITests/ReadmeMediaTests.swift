// README and launch media (docs/media/): hero.png, menubar-marks.png, spotlight.png, catch.gif and docs/media/x/
// (launch-card.png, catch.mp4). Skipped unless OBSCURA_RENDER_MEDIA=1; docs/media/README.md says how to regenerate.
// Real Vision runs (the engine's own covers), so this is also skipped under CI like the other Vision tests.
// Every secret is made up (SampleData); messages and logs carry counts only.
import AppKit
import CoreGraphics
import Foundation
import Testing
import ObscuraPrefs
import ObscuraSearch
import ObscuraUIKit
@testable import ObscuraThumbnailUI

@MainActor
enum MediaSample {
    private static var cached: CaughtSample?

    /// The engine's catch of the sample terminal, made once per test process.
    static func get() async throws -> CaughtSample {
        if let cached { return cached }
        let sample = try await CaughtSample.make()
        cached = sample
        return sample
    }

    private static var cachedSearch: CaughtSample?

    /// A second real catch, of a terminal showing only the made-up Anthropic key: its Spotlight title is short enough to
    /// read whole in one row, where the four-key screenshot's title runs past the row and is cut off.
    static func search() async throws -> CaughtSample {
        if let cachedSearch { return cachedSearch }
        let sample = try await CaughtSample.make(lines: ["$ cat .env.local", SampleData.envLines[2]],
                                                 displayName: "Screenshot 2026-10-28 at 4.12.08 PM.png")
        cachedSearch = sample
        return sample
    }
}

@Suite(.serialized) @MainActor struct ReadmeMediaTests {
    nonisolated static var on: Bool { Media.enabled && ProcessInfo.processInfo.environment["CI"] == nil }

    // MARK: hero.png — before / after

    @Test(.enabled(if: on)) func hero() async throws {
        let s = try await MediaSample.get()
        #expect(s.pieces.count == SampleData.secretLines.count, "\(s.pieces.count) covers")
        let tw = s.pointSize.width, th = s.pointSize.height, margin: CGFloat = 40, labelGap: CGFloat = 30, between: CGFloat = 34
        let size = CGSize(width: tw + 2 * margin, height: margin + 2 * (labelGap + th) + between + margin - 6)
        let c = Canvas(size: size, scale: 2)
        c.desk(dark: false)
        let rows: [(String, String, Bool)] = [("BEFORE", "A terminal screenshot with four made-up keys", false),
                                              ("AFTER", "The same screenshot after Obscura’s engine checked it, on this Mac", true)]
        var top = margin - 6
        for (label, note, covered) in rows {
            let w = c.text(label, x: margin + 2, baseline: top + 14, font: Canvas.font(12.5, .semibold), color: Media.text2, kern: 1.1)
            c.text(note, x: margin + 2 + w + 12, baseline: top + 14, font: Canvas.font(13), color: Media.text3)
            top += labelGap
            s.draw(on: c, in: c.r(margin, top, tw, th), snapAt: covered ? 10 : nil, radius: 10)
            top += th + between
        }
        try Media.writePNG(c.image(), to: try Media.url("hero.png"))
    }

    // MARK: menubar-marks.png — the 16 marks in Warm, light and dark

    @Test(.enabled(if: on)) func menuBarMarks() async throws {
        let marks = MenuBarMarkID.allCases
        #expect(marks.count == 16)
        let columns = 8, cell: CGFloat = 112, strip: CGFloat = 54, nameRow: CGFloat = 30, margin: CGFloat = 32, rowGap: CGFloat = 26
        let rows = (marks.count + columns - 1) / columns
        let size = CGSize(width: CGFloat(columns) * cell + 2 * margin,
                          height: margin + CGFloat(rows) * (2 * strip + nameRow) + CGFloat(rows - 1) * rowGap + margin - 8)
        let c = Canvas(size: size, scale: 2)
        c.fill(Media.rgb(0xF6F6F8))
        let markPoints: CGFloat = 18, shown: CGFloat = 32
        for row in 0..<rows {
            let top = margin + CGFloat(row) * (2 * strip + nameRow + rowGap)
            let light = c.r(margin, top, CGFloat(columns) * cell, strip), dark = c.r(margin, top + strip, CGFloat(columns) * cell, strip)
            // The strips: the menu bar's light and dark colours (as the mark contact sheets use), one rounded block.
            c.ctx.saveGState()
            c.ctx.addPath(c.roundedPath(light.union(dark), 12)); c.ctx.clip()
            c.fill(Media.rgb(0xECECF0), light)
            c.fill(Media.rgb(0x202024), dark)
            c.ctx.restoreGState()
            c.ctx.addPath(c.roundedPath(light.union(dark).insetBy(dx: 0.25, dy: 0.25), 12))
            c.ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12)); c.ctx.setLineWidth(0.5); c.ctx.strokePath()
            for col in 0..<columns {
                let index = row * columns + col
                guard index < marks.count else { break }
                let mark = marks[index]
                let x = margin + CGFloat(col) * cell
                for (k, appearance) in [MarkAppearance.light, .dark].enumerated() {
                    let look = MarkLook(pointSize: markPoints, appearance: appearance)
                    let frame = MarkFrame(mark: mark, style: .warm, state: .protected)
                    let image = try #require(OwnPieces.mark(frame, look, scale: 2 * shown / markPoints))
                    let w = CGFloat(image.width) / 2, h = CGFloat(image.height) / 2
                    c.ctx.draw(image, in: c.r(x + (cell - w) / 2, top + CGFloat(k) * strip + (strip - h) / 2, w, h))
                }
                c.text(mark.title, x: x + cell / 2, baseline: top + 2 * strip + 20, font: Canvas.font(12.5, .medium), color: Media.text2,
                       align: .center, maxWidth: cell - 6)
            }
        }
        try Media.writePNG(c.image(), to: try Media.url("menubar-marks.png"))
    }

    // MARK: spotlight.png — an illustration of the Spotlight result

    @Test(.enabled(if: on)) func spotlight() async throws {
        let s = try await MediaSample.search()
        let item = s.searchItem()
        #expect(item.title.hasPrefix("Covered screenshot — "))
        #expect(item.title.contains("Anthropic API key"))
        let size = CGSize(width: 960, height: 330)
        let c = Canvas(size: size, scale: 2)
        c.desk(dark: false)
        Scenes.spotlight(c, x: (size.width - 720) / 2, top: 44, width: 720, query: "Anthropic API key", caret: false, result: 1,
                         item: item, thumbnail: s.clean)
        c.text("Illustration of a Spotlight result for a covered screenshot. The entry carries the kind of secret, never the secret.",
               x: size.width / 2, baseline: size.height - 30, font: Canvas.font(12.5), color: Media.text2, align: .center)
        try Media.writePNG(c.image(), to: try Media.url("spotlight.png"))
    }

    // MARK: catch.gif — the catch, ≤ 6 s

    @Test(.enabled(if: on)) func catchGIF() async throws {
        let s = try await MediaSample.get()
        let card = try #require(OwnPieces.thumbnail(clean: s.clean, covered: s.pieces.count))
        let scene = Scenes.CatchScene(sample: s, card: card)
        // Frames only where something moves; holds are one frame with a long delay (GIF frames are whole pictures).
        let step = 0.04
        var times: [(Double, Double)] = [(0, scene.snapStart)]
        var t = scene.snapStart
        while t < scene.snapEnd { times.append((t, step)); t += step }
        times.append((scene.snapEnd, scene.cardStart - scene.snapEnd))
        t = scene.cardStart
        while t < scene.cardEnd { times.append((t, step)); t += step }
        times.append((scene.cardEnd, scene.loop - scene.cardEnd))
        let total = times.map(\.1).reduce(0, +)
        #expect(total <= 6.0001, "\(total) s")
        let frames = times.map { (image: scene.frame(at: $0.0), delay: $0.1) }
        let url = try Media.url("catch.gif")
        try Media.writeGIF(frames, to: url)
        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(bytes <= 2_000_000, "catch.gif is \(bytes) bytes")
    }

    // MARK: x/launch-card.png — 1600 × 900

    @Test(.enabled(if: on)) func launchCard() async throws {
        let s = try await MediaSample.get()
        let icon = try #require(Media.appIcon())
        let size = CGSize(width: 1600, height: 900)
        let c = Canvas(size: size, scale: 1)
        c.desk(dark: true)
        let left: CGFloat = 104
        c.ctx.draw(icon, in: c.r(left - 18, 150, 196, 196))
        c.text("Obscura", x: left, baseline: 446, font: Canvas.font(92, .bold), color: Media.rgb(0xFFFFFF))
        let pitch = ["Covers the secrets in your", "screenshots before you share them."]
        for (i, line) in pitch.enumerated() {
            c.text(line, x: left, baseline: 520 + CGFloat(i) * 46, font: Canvas.font(36, .medium), color: Media.rgb(0xFFFFFF, 0.88))
        }
        let facts = "On-device  ·  Open source  ·  Free  ·  macOS 15+"
        c.text(facts, x: left, baseline: 660, font: Canvas.font(25, .medium), color: Media.accentDark)
        // Before / after, the engine's real covers.
        let tw: CGFloat = 760, th = tw * s.pointSize.height / s.pointSize.width, x = size.width - 96 - tw
        let blockTop = (size.height - (2 * th + 2 * 40 + 36)) / 2
        var top = blockTop
        for (label, covered) in [("BEFORE", false), ("AFTER", true)] {
            c.text(label, x: x + 2, baseline: top + 22, font: Canvas.font(19, .semibold), color: Media.rgb(0xFFFFFF, 0.62), kern: 1.6)
            top += 40
            s.draw(on: c, in: c.r(x, top, tw, th), snapAt: covered ? 10 : nil, radius: 12, dark: true)
            top += th + 36
        }
        try Media.writePNG(c.image(), to: try Media.url("x/launch-card.png"), retina: false)
    }

    // MARK: x/catch.mp4 — 1280 × 720, H.264, no audio

    @Test(.enabled(if: on)) func launchVideo() async throws {
        let s = try await MediaSample.get()
        let card = try #require(OwnPieces.thumbnail(clean: s.clean, covered: s.pieces.count))
        let icon = try #require(Media.appIcon())
        let found = try await MediaSample.search()
        let film = Scenes.Film(sample: s, card: card, icon: icon, item: found.searchItem(), found: found.clean)
        let fps = 30
        let url = try Media.url("x/catch.mp4")
        try await Media.writeMP4(to: url, width: 1280, height: 720, fps: fps, frames: Int(film.duration * Double(fps)), bitRate: 2_400_000) { i in
            film.frame(at: Double(i) / Double(fps))
        }
        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(bytes > 0 && bytes < 15_000_000, "catch.mp4 is \(bytes) bytes")
        // Stills of the film's key moments, for the person checking it (scratch, never committed).
        if let dir = ProcessInfo.processInfo.environment["OBSCURA_MEDIA_STILLS_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for t in [0.5, 1.2, 1.75, 2.1, 2.5, 3.4, 5.2, 6.3, 7.5, 10.6, 12.5, 15.5, 17.5] {
                try Media.writePNG(film.frame(at: t), to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "film-%05.2f.png", t)),
                                   retina: false)
            }
        }
    }
}

// MARK: - Scenes

@MainActor
enum Scenes {
    /// Spotlight's panel, drawn plainly as an illustration: a search row with `query`, then Obscura's one result (the
    /// real CatchSearchItem title and description, with the covered image as its thumbnail), selected.
    static func spotlight(_ c: Canvas, x: CGFloat, top: CGFloat, width: CGFloat, query: String, caret: Bool, result: CGFloat,
                          item: SearchItemContent, thumbnail: CGImage) {
        let searchRow: CGFloat = 58, header: CGFloat = 30, row: CGFloat = 58
        let height = searchRow + (result > 0 ? 1 + header + row + 10 : 0)
        let panel = c.r(x, top, width, height)
        c.panel(panel, radius: 18, color: Media.rgb(0xF7F7F9, 0.97))
        // The magnifying glass.
        let glass = c.r(x + 22, top + 19, 15, 15)
        c.ctx.setStrokeColor(Media.text3); c.ctx.setLineWidth(2.2)
        c.ctx.strokeEllipse(in: glass)
        c.ctx.setLineCap(.round)
        c.ctx.move(to: CGPoint(x: glass.maxX - 2, y: glass.minY + 2)); c.ctx.addLine(to: CGPoint(x: glass.maxX + 4.5, y: glass.minY - 4.5))
        c.ctx.strokePath()
        let font = Canvas.font(23)
        let typed = c.text(query, x: x + 54, baseline: top + 37, font: font, color: Media.text)
        if caret { c.fill(Media.rgb(0x1D1D1F), c.r(x + 55 + typed, top + 17, 2, 27)) }
        guard result > 0 else { return }
        c.ctx.saveGState()
        c.ctx.setAlpha(result)
        c.fill(CGColor(gray: 0, alpha: 0.08), c.r(x + 14, top + searchRow, width - 28, 1))
        c.text("Obscura", x: x + 22, baseline: top + searchRow + 21, font: Canvas.font(12, .semibold), color: Media.text3)
        let rowRect = c.r(x + 10, top + searchRow + header, width - 20, row)
        c.ctx.addPath(c.roundedPath(rowRect, 10)); c.ctx.setFillColor(Media.rgb(0x2F6FE0)); c.ctx.fillPath()
        // The thumbnail: the covered picture, its left part filling a small rounded tile.
        let tile = c.r(x + 20, top + searchRow + header + 9, 64, 40)
        let cropWidth = Int(CGFloat(thumbnail.height) * tile.width / tile.height)
        if let crop = thumbnail.cropping(to: CGRect(x: 0, y: 0, width: min(cropWidth, thumbnail.width), height: thumbnail.height)) {
            c.ctx.saveGState()
            c.ctx.addPath(c.roundedPath(tile, 6)); c.ctx.clip()
            c.ctx.draw(crop, in: tile)
            c.ctx.restoreGState()
            c.ctx.addPath(c.roundedPath(tile.insetBy(dx: 0.25, dy: 0.25), 6))
            c.ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35)); c.ctx.setLineWidth(0.5); c.ctx.strokePath()
        }
        let textX = x + 98, textWidth = width - 98 - 24
        c.text(item.title, x: textX, baseline: top + searchRow + header + 25, font: Canvas.font(15, .semibold), color: Media.rgb(0xFFFFFF),
               maxWidth: textWidth)
        c.text(item.displayName, x: textX, baseline: top + searchRow + header + 45, font: Canvas.font(12.5),
               color: Media.rgb(0xFFFFFF, 0.78), maxWidth: textWidth)
        c.ctx.restoreGState()
    }

    /// A plain menu bar strip (no logos, no menus): the mark and a clock at the right.
    static func menuBar(_ c: Canvas, mark: CGImage, height: CGFloat = 26, clock: String = "Wed 9:41") {
        c.fill(Media.rgb(0xF4F4F7, 0.86), c.r(0, 0, c.size.width, height))
        c.fill(CGColor(gray: 0, alpha: 0.06), c.r(0, height, c.size.width, 0.5))
        let clockWidth = c.text(clock, x: c.size.width - 16, baseline: height / 2 + 5, font: Canvas.font(13.5, .medium), color: Media.text,
                                align: .right)
        let w = CGFloat(mark.width) / CGFloat(c.ctx.ctm.a), h = CGFloat(mark.height) / CGFloat(c.ctx.ctm.a)
        c.ctx.draw(mark, in: c.r(c.size.width - 16 - clockWidth - 18 - w, (height - h) / 2, w, h))
    }

    /// The menu bar mark (Dissolving, Warm: the mark the launch media shows) at `t` seconds relative to the catch.
    static func markFrame(sinceCatch t: Double?, checkingFor: Double? = nil, scale: CGFloat) -> CGImage? {
        let mark = MenuBarMarkID.dissolving
        let look = MarkLook(pointSize: 18, appearance: .light)
        let pieces = mark.designedPieceCount
        var frame = MarkFrame(mark: mark, style: .warm, state: .protected)
        if let t, t >= 0 {
            let snap = MarkTimeline.duration(.caught, pieces: pieces)
            if t < snap {
                frame = MarkFrame(mark: mark, style: .warm, state: .caught, pose: MarkTimeline.pose(.caught, pieces: pieces, at: t))
            } else if t < snap + 4 {
                frame = MarkFrame(mark: mark, style: .warm, state: .caught)
            }
        } else if let checking = checkingFor {
            var pose = MarkPose()
            pose.scanY = MarkTimeline.scanY(at: checking)
            frame = MarkFrame(mark: mark, style: .warm, state: .checking, pose: pose)
        }
        return OwnPieces.mark(frame, look, scale: scale)
    }

    // MARK: The GIF

    struct CatchScene {
        let sample: CaughtSample
        let card: CGImage
        let size = CGSize(width: 880, height: 420)
        let scale: CGFloat = 2
        let snapStart = 0.9
        var snapDuration: Double {
            max(MarkTimeline.duration(.caught, pieces: sample.pieces.count),
                MarkTimeline.duration(.caught, pieces: MenuBarMarkID.dissolving.designedPieceCount))
        }
        var snapEnd: Double { snapStart + snapDuration }
        var cardStart: Double { snapEnd + 0.25 }
        var cardEnd: Double { cardStart + OMotion.slideDuration }
        let loop = 5.0

        @MainActor
        func frame(at t: Double) -> CGImage {
            let c = Canvas(size: size, scale: scale)
            c.fill(Media.rgb(0xE2DEF0))
            let markImage = Scenes.markFrame(sinceCatch: t >= snapStart ? t - snapStart : nil, scale: scale)
            if let markImage { Scenes.menuBar(c, mark: markImage) }
            let tw: CGFloat = 800, th = tw * sample.pointSize.height / sample.pointSize.width
            sample.draw(on: c, in: c.r((size.width - tw) / 2, 62, tw, th), snapAt: t >= snapStart ? t - snapStart : nil, radius: 10)
            if t >= cardStart {
                Scenes.drawCard(c, card, progress: Media.easeOut((t - cardStart) / OMotion.slideDuration), inset: 10)
            }
            // GIF has 256 colours a frame: a shadow's faintest edge, a shade off the backdrop, would be given its own
            // palette entry and show as a hard-edged box. Pixels within 3 levels of the backdrop become the backdrop.
            Media.snap(c.ctx, to: (0xE2, 0xDE, 0xF0), tolerance: 3)
            return c.image()
        }
    }

    /// The thumbnail panel at the bottom-right corner, sliding in from the right as `progress` goes 0 → 1. `zoom` enlarges
    /// it (the film's frame is smaller than a real screen, so the card is shown a little larger to stay readable).
    static func drawCard(_ c: Canvas, _ card: CGImage, progress: Double, zoom: CGFloat = 1, inset: CGFloat = 4) {
        let image = CGSize(width: OwnPieces.thumbnailImageSize.width * zoom, height: OwnPieces.thumbnailImageSize.height * zoom)
        let bleed = OwnPieces.thumbnailBleed * zoom
        // The panel's own box sits `inset` from the corner; the bleed around it may run past the canvas edge.
        let x = c.size.width - image.width + bleed - inset + (1 - CGFloat(progress)) * (image.width - bleed + inset + 8)
        c.ctx.draw(card, in: c.r(x, c.size.height - image.height + bleed - inset, image.width, image.height))
    }

    // MARK: The film

    struct Film {
        let sample: CaughtSample
        let card: CGImage
        let icon: CGImage
        let item: SearchItemContent
        /// The covered picture Spotlight's result shows (the catch `item` describes).
        let found: CGImage
        let size = CGSize(width: 1280, height: 720)
        let duration = 18.0

        // Scene 1: the screenshot and the catch.
        let selectStart = 0.8, selectEnd = 1.45, shot = 1.6, checkStart = 1.75, snapStart = 2.35
        var cardStart: Double { snapStart + 0.55 }
        // Scene 2: ⌘V. Scene 3: Spotlight. Scene 4: the end card.
        let scene2 = 5.4, pasteKeys = 6.2, paste = 6.75, scene3 = 9.9, typeStart = 10.5, perChar = 0.075, scene4 = 14.9
        let fade = 0.4

        var terminalWidth: CGFloat { 1000 }
        var terminalRect: (x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) {
            let w = terminalWidth, h = w * sample.pointSize.height / sample.pointSize.width
            return ((size.width - w) / 2, 104, w, h)
        }

        @MainActor
        func frame(at t: Double) -> CGImage {
            let c = Canvas(size: size, scale: 1)
            let cuts: [(Double, (Canvas, Double) -> Void)] = [(0, sceneShot), (scene2, scenePaste), (scene3, sceneSearch), (scene4, sceneEnd)]
            var current = 0
            for (i, cut) in cuts.enumerated() where t >= cut.0 { current = i }
            cuts[current].1(c, t)
            // Cross-fade from the previous scene: the new scene fades in over the old one's last moment.
            if current > 0, t < cuts[current].0 + fade {
                let a = CGFloat(Media.easeInOut((t - cuts[current].0) / fade))
                let old = Canvas(size: size, scale: 1)
                cuts[current - 1].1(old, cuts[current].0)
                c.ctx.saveGState()
                c.ctx.setAlpha(1 - a)
                c.ctx.draw(old.image(), in: CGRect(origin: .zero, size: size))
                c.ctx.restoreGState()
            }
            return c.image()
        }

        func caption(_ c: Canvas, _ text: String, alpha: CGFloat = 1) {
            c.ctx.saveGState()
            c.ctx.setAlpha(alpha)
            c.text(text, x: size.width / 2, baseline: 672, font: Canvas.font(33, .semibold), color: Media.text, align: .center)
            c.ctx.restoreGState()
        }

        func keysRow(_ c: Canvas, _ symbols: [String], top: CGFloat, alpha: CGFloat) {
            guard alpha > 0 else { return }
            let height: CGFloat = 62
            let w = Canvas.keysWidth(symbols, height: height, gap: 12)
            c.keys(symbols, x: (size.width - w) / 2, top: top, height: height, gap: 12, alpha: alpha)
        }

        @MainActor
        func menuBar(_ c: Canvas, t: Double) {
            let mark: CGImage?
            if t >= snapStart { mark = Scenes.markFrame(sinceCatch: t - snapStart, scale: 1) }
            else if t >= checkStart { mark = Scenes.markFrame(sinceCatch: nil, checkingFor: t - checkStart, scale: 1) }
            else { mark = Scenes.markFrame(sinceCatch: nil, scale: 1) }
            if let mark { Scenes.menuBar(c, mark: mark, height: 30) }
        }

        @MainActor
        func sceneShot(_ c: Canvas, _ t: Double) {
            c.desk(dark: false)
            let (x, top, w, h) = terminalRect
            // After the shutter the picture lifts a little off the screen: it is now the screenshot file being checked.
            let lift = CGFloat(Media.easeOut((t - shot) / 0.35))
            let k = 1 - 0.06 * lift
            let rect = c.r(x + w * (1 - k) / 2, top + h * (1 - k) / 2 - 10 * lift, w * k, h * k)
            sample.draw(on: c, in: rect, snapAt: t >= snapStart ? t - snapStart : nil, radius: 12)
            // The ⇧⌘4 selection: a translucent rectangle growing from the top-left corner, with the crosshair.
            if t >= selectStart && t < shot {
                let p = CGFloat(Media.easeInOut((t - selectStart) / (selectEnd - selectStart)))
                let sel = c.r(x - 8, top - 8, (w + 16) * max(0.02, p), (h + 16) * max(0.02, p))
                c.fill(CGColor(gray: 0.5, alpha: 0.22), sel)
                c.ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); c.ctx.setLineWidth(1); c.ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))
                let corner = CGPoint(x: sel.maxX, y: sel.minY)
                c.ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 0.9)); c.ctx.setLineWidth(1.5)
                c.ctx.move(to: CGPoint(x: corner.x - 12, y: corner.y)); c.ctx.addLine(to: CGPoint(x: corner.x + 12, y: corner.y))
                c.ctx.move(to: CGPoint(x: corner.x, y: corner.y - 12)); c.ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + 12))
                c.ctx.strokePath()
            }
            // The shutter flash.
            if t >= shot && t < shot + 0.25 {
                c.fill(CGColor(gray: 1, alpha: CGFloat(0.7 * (1 - (t - shot) / 0.25))))
            }
            menuBar(c, t: t)
            keysRow(c, ["⇧", "⌘", "4"], top: 440, alpha: CGFloat(Media.ramp(t, 0.35, 0.2) * (1 - Media.ramp(t, 1.9, 0.25))))
            if t < snapStart - 0.1 {
                caption(c, "Take a screenshot as usual", alpha: CGFloat(Media.ramp(t, 0.2, 0.3) * (1 - Media.ramp(t, snapStart - 0.35, 0.25))))
            } else {
                caption(c, "Obscura covers every key, on this Mac", alpha: CGFloat(Media.ramp(t, snapStart - 0.1, 0.25)))
            }
            if t >= cardStart {
                Scenes.drawCard(c, card, progress: Media.easeOut((t - cardStart) / OMotion.slideDuration), zoom: 1.4, inset: 12)
            }
        }

        @MainActor
        func scenePaste(_ c: Canvas, _ t: Double) {
            c.desk(dark: false)
            // A plain message window (an illustration, no real app): title bar, a line of text, then the pasted picture.
            let win = (x: CGFloat(250), top: CGFloat(84), w: CGFloat(780), h: CGFloat(410))
            let rect = c.r(win.x, win.top, win.w, win.h)
            c.panel(rect, radius: 14, color: Media.rgb(0xFFFFFF))
            c.ctx.saveGState()
            c.ctx.addPath(c.roundedPath(rect, 14)); c.ctx.clip()
            c.fill(Media.rgb(0xF2F2F5), c.r(win.x, win.top, win.w, 44))
            c.fill(CGColor(gray: 0, alpha: 0.08), c.r(win.x, win.top + 44, win.w, 0.5))
            c.ctx.restoreGState()
            c.windowButtons(x: win.x + 16, top: win.top + 16)
            c.text("New message", x: win.x + win.w / 2, baseline: win.top + 27, font: Canvas.font(14, .semibold), color: Media.text2, align: .center)
            let body = c.text("Here’s the config from the deploy box:", x: win.x + 30, baseline: win.top + 86, font: Canvas.font(19),
                              color: Media.text)
            let pasted = t >= paste
            if !pasted, (t * 2).truncatingRemainder(dividingBy: 1) < 0.5 {
                c.fill(Media.text, c.r(win.x + 32 + body, win.top + 68, 2, 24))
            }
            if pasted {
                let a = CGFloat(Media.easeOut((t - paste) / 0.18))
                let iw = win.w - 60, ih = iw * sample.pointSize.height / sample.pointSize.width
                let k = 0.97 + 0.03 * a
                c.card(sample.clean, c.r(win.x + 30 + iw * (1 - k) / 2, win.top + 112 + ih * (1 - k) / 2, iw * k, ih * k), radius: 10,
                       shadow: false, alpha: a)
            }
            menuBar(c, t: t)
            keysRow(c, ["⌘", "V"], top: 528, alpha: CGFloat(Media.ramp(t, pasteKeys, 0.2) * (1 - Media.ramp(t, paste + 1.1, 0.3))))
            caption(c, "⌘V pastes the covered copy, never the original")
        }

        @MainActor
        func sceneSearch(_ c: Canvas, _ t: Double) {
            c.desk(dark: false)
            menuBar(c, t: t)
            let query = "Anthropic API key"
            let typed = max(0, min(query.count, Int((t - typeStart) / perChar)))
            let done = typeStart + Double(query.count) * perChar
            let result = CGFloat(Media.easeOut((t - done - 0.12) / 0.2))
            let caretOn = typed < query.count || (t * 2).truncatingRemainder(dividingBy: 1) < 0.5
            Scenes.spotlight(c, x: (size.width - 860) / 2, top: 150, width: 860, query: String(query.prefix(typed)), caret: caretOn,
                             result: result, item: item, thumbnail: found)
            c.text("Illustration", x: (size.width + 860) / 2, baseline: 136, font: Canvas.font(13, .medium), color: Media.text3, align: .right)
            caption(c, "Find it later by the kind of secret, never the secret")
        }

        @MainActor
        func sceneEnd(_ c: Canvas, _ t: Double) {
            c.desk(dark: false)
            let iconSize: CGFloat = 176
            c.ctx.draw(icon, in: c.r((size.width - iconSize) / 2, 128, iconSize, iconSize))
            c.text("Obscura", x: size.width / 2, baseline: 400, font: Canvas.font(66, .bold), color: Media.text, align: .center)
            c.text("Covers the secrets in your screenshots before you share them.", x: size.width / 2, baseline: 456,
                   font: Canvas.font(27, .medium), color: Media.text2, align: .center)
            c.text("On-device  ·  Open source  ·  Free  ·  macOS 15+", x: size.width / 2, baseline: 516, font: Canvas.font(22, .medium),
                   color: Media.accent, align: .center)
        }
    }
}
