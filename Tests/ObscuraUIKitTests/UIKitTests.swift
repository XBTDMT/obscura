import Testing
import Foundation
import ImageIO
@testable import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal

@Suite struct VerdictTests {
    @Test func allCoveredIsSafe() { #expect(Verdict(enabled: 4, total: 4) == .safeToShare(total: 4)) }
    @Test func noneCoveredIsOriginal() { #expect(Verdict(enabled: 0, total: 4) == .originalShowing(total: 4)) }
    @Test func someCoveredIsLeftVisible() { #expect(Verdict(enabled: 3, total: 4) == .leftVisible(visible: 1, total: 4)) }
    @Test func tonesKeepOneMeaning() {
        #expect(Verdict.safeToShare(total: 1).tone == .ok)
        #expect(Verdict.leftVisible(visible: 1, total: 2).tone == .needs)
        #expect(Verdict.originalShowing(total: 2).tone == .live)
    }
    @Test func countsAreGrammatical() {
        #expect(ProtectionCopy.secrets(1) == "1 secret")
        #expect(ProtectionCopy.secrets(3) == "3 secrets")
    }
}

@Suite @MainActor struct AppModelTests {
    @Test func sampleModelLoadsEntriesAndVerdicts() async throws {
        let model = try await SampleData.model(entries: 6)
        #expect(model.entries.count == 6)
        let leftVisible = model.entries.filter { if case .leftVisible = model.verdict(for: $0) { return true } else { return false } }
        #expect(leftVisible.count == 1)
    }

    @Test func markPrecedence() async throws {
        let model = try await SampleData.model(entries: 0)
        #expect(model.markState == .protected)
        model.updateOffer = UpdateOffer(version: "1.1")
        #expect(model.markState == .waiting)
    }

    @Test func trashOffersUndoThatRestores() async throws {
        let model = try await SampleData.model(entries: 2)
        let id = try #require(model.entries.first?.id)
        await model.trash([id])
        #expect(model.entries.count == 1)
        #expect(model.toast?.undo != nil)
        await model.restore([id])
        #expect(model.entries.count == 2)
    }

    @Test func detectorTitlesResolve() {
        #expect(DetectorNames.title(for: "payments.stripe.secretkey") != "payments.stripe.secretkey")
        #expect(DetectorNames.title(for: "custom.ABC") == "Your rule")
    }
}

@Suite @MainActor struct MarkTests {
    @Test func everyStateRendersAMenuBarImage() {
        for state in MarkState.allCases {
            let image = ObscuraMarkDrawing.menuBarImage(state)
            #expect(image.size.width == 18)
            #expect(image.isTemplate == !(state == .caught || state == .needsAttention || state == .waiting || state == .focusHolding))
        }
    }
}

@Suite struct SampleDataTests {
    @Test func terminalRendersPNG() {
        let data = SampleData.terminalPNG(covered: true)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    /// The PNG decoded into a known layout: sRGB, 8-bit RGBA, row 0 at the top.
    private struct Pixels {
        let width: Int, height: Int
        private let bytes: [UInt8]
        init?(_ data: Data) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let w = image.width, h = image.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            width = w; height = h; bytes = buf
        }
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        func distance(_ x: Int, _ y: Int, _ c: (Int, Int, Int)) -> Int {
            let (r, g, b) = rgb(x, y)
            return abs(r - c.0) + abs(g - c.1) + abs(b - c.2)
        }
        /// The terminal background, read from the top-left corner (inside the padding, never drawn on).
        var background: (Int, Int, Int) { rgb(2, 2) }
        /// Anything that is not the terminal background is ink (text or bar).
        func isInk(_ x: Int, _ y: Int) -> Bool { distance(x, y, background) > 24 }
    }

    @Test func pixelSizeMatchesTheImageItDescribes() throws {
        for (width, scale) in [(960, CGFloat(2)), (560, 2), (380, 1)] {
            let layout = SampleData.TerminalLayout(width: width, scale: scale)
            let image = try #require(Pixels(SampleData.terminalPNG(covered: false, width: width, scale: scale)))
            #expect(image.width == Int(layout.pixelSize.width))
            #expect(image.height == Int(layout.pixelSize.height))
        }
        #expect(SampleData.TerminalLayout().pixelSize == CGSize(width: 1920, height: 508))
    }

    @Test func seedRectsSitOverTheDrawnValues() throws {
        let layout = SampleData.TerminalLayout()
        let plain = try #require(Pixels(SampleData.terminalPNG(covered: false)))
        let covered = try #require(Pixels(SampleData.terminalPNG(covered: true)))
        let findings = SampleData.terminalFindings(layout: layout)
        #expect(findings.map(\.lineIndex) == SampleData.secretLines.map(\.line))
        for f in findings {
            let r = f.rect
            // The value's ink in the plain image: everything from the rect's first pixel column rightwards, within the
            // line's band (half the 12-pixel gap to each neighbouring line). The `=` ink ends 1 px before that column
            // and the value's starts 2 px after it, so a bar that starts late (the old +2 pt offset left 4 px of the
            // first character showing) fails here.
            let x0 = Int(r.minX.rounded(.down)), rows = Int(r.minY) - 6..<Int(r.maxY) + 6
            var ink = CGRect.null, inkPixels = 0
            for y in rows {
                for x in x0..<plain.width where plain.isInk(x, y) {
                    ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
                    inkPixels += 1
                }
            }
            #expect(inkPixels > 200, "line \(f.lineIndex) drew its value")
            #expect(r.contains(ink), "line \(f.lineIndex): the value's ink \(ink) lies inside the finding rect \(r)")
            // The covered image has a near-black bar at the rect's centre...
            let bar = covered.rgb(Int(r.midX), Int(r.midY))
            #expect(bar.0 + bar.1 + bar.2 < 90, "line \(f.lineIndex): a bar is drawn over the rect, \(bar)")
            // ...every value pixel is under it, and none of it falls outside the rect.
            var uncovered = 0, strayBar = 0
            for y in rows {
                for x in x0..<covered.width {
                    let isBar = covered.distance(x, y, bar) <= 6
                    if plain.isInk(x, y), !isBar { uncovered += 1 }
                    if isBar, !r.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) { strayBar += 1 }
                }
            }
            #expect(uncovered == 0, "line \(f.lineIndex): no value pixel shows beside its bar")
            #expect(strayBar == 0, "line \(f.lineIndex): the bar is drawn inside the finding rect")
        }
    }

    @Test func aLeftVisibleLineDrawsNoBar() throws {
        let layout = SampleData.TerminalLayout()
        let line = SampleData.secretLines[3].line
        let partly = try #require(Pixels(SampleData.terminalPNG(covered: true, leftVisible: [line])))
        let plain = try #require(Pixels(SampleData.terminalPNG(covered: false)))
        let full = try #require(Pixels(SampleData.terminalPNG(covered: true)))
        for item in SampleData.secretLines {
            let r = try #require(layout.valueRect(line: item.line))
            let rows = Int(r.minY)..<Int(r.maxY), cols = Int(r.minX)..<Int(r.maxX)
            // The left-visible line matches the plain image pixel for pixel; every other line matches the covered one.
            let reference = item.line == line ? plain : full
            let differing = rows.reduce(0) { n, y in n + cols.filter { partly.rgb($0, y) != reference.rgb($0, y) }.count }
            #expect(differing == 0, "line \(item.line)")
        }
    }

    @Test func seededEntriesCarryTheLayoutsRectsAndSize() async throws {
        let journal = try SampleData.makeJournal()
        try await SampleData.seed(journal, count: 2)
        let entries = try await journal.entries(matching: EntryQuery())
        let layout = SampleData.TerminalLayout()
        let expected = SampleData.terminalFindings(layout: layout).map(\.rect)
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.pixelWidth == 1920 && entry.pixelHeight == 508)
            let rects = entry.findings.sorted { $0.lineIndex < $1.lineIndex }.map(\.rect)
            #expect(rects.count == expected.count)
            for (a, b) in zip(rects, expected) {
                #expect(abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01)
            }
        }
    }
}

@Suite @MainActor struct SettingsMirrorTests {
    @Test func aChangeIsVisibleOnTheModelAtOnce() async throws {
        let model = try await SampleData.model(entries: 0)
        model.updateSettings { $0.guardsDownloads = true }
        #expect(model.settings.guardsDownloads == true)
        model.pause(for: nil)
        #expect(model.settings.protectionPaused == true)
        model.resume()
        #expect(model.settings.protectionPaused == false)
    }
}

@Suite @MainActor struct SampleRouterTests {
    @Test func sampleModelKeepsItsRouter() async throws {
        let model = try await SampleData.model(entries: 1)
        model.router?.openSettings(.detectors)
        #expect((model.router as? RecordingRouter)?.calls == ["settings:detectors"])
    }
}
