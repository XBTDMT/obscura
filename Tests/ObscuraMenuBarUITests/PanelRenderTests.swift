// Renders the panel and the menu bar mark in every state, light and dark, and checks size and that something drew.
// With OBSCURA_UI_RENDER_DIR set, the PNGs are written there for a visual check against menubar.html.
import Foundation
import AppKit
import SwiftUI
import Testing
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
@testable import ObscuraMenuBarUI

@MainActor
@Suite struct PanelRenderTests {
    static let outputDirectory: URL? = ProcessInfo.processInfo.environment["OBSCURA_UI_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// Every state tile on the mockup page, as inputs.
    static func states() -> [(String, PanelInputs)] {
        let lc = LastCatch(entryID: TestData.stripeAndEmail.id, displayName: TestData.stripeAndEmail.displayName, findings: 2,
                           date: TestData.date(9, 41, 12))
        let denied = Problem(kind: .folderAccess, messageKey: "problem.folder.denied", url: TestData.downloads)
        let failed = Problem(kind: .scanFailure, messageKey: "problem.scan.failed", detail: "1")
        let card = TestData.entry("Screenshot 2026-10-26 at 9.42.40 AM.png", at: TestData.date(9, 42, 40), cleanCopy: true,
                                  detectors: [("personal.card.pan", true)])
        let undone = TestData.entry("Screenshot 2026-10-26 at 9.41.12 AM.png", at: TestData.date(9, 41, 12),
                                    detectors: [("payments.stripe.secretkey", false)])
        let token = TestData.entry("Copied image", at: TestData.date(9, 41, 50), source: .clipboard, detectors: [("scm.github.token", true)])
        return [
            ("caught", TestData.inputs(status: EngineStatus(lastCatch: lc, weekStats: TestData.week(today: 2)))),
            ("idle", TestData.inputs(now: TestData.date(10, 5))),
            ("checking", TestData.inputs(status: EngineStatus(inFlight: 3, queueDepth: 3, weekStats: TestData.week()), checkingPeak: 3)),
            ("needs", TestData.inputs(status: EngineStatus(protection: .needsAttention(problems: [denied, failed]),
                                                           weekStats: TestData.week(), problems: [denied, failed],
                                                           unchecked: [UncheckedData.file("IMG_0412.heic")]),
                                      now: TestData.date(10, 5))),
            ("paused", TestData.inputs(status: EngineStatus(protection: .paused, weekStats: TestData.week()),
                                       pause: PauseState(since: TestData.date(9, 30), resumesAt: TestData.date(10, 30)),
                                       now: TestData.date(10, 5))),
            ("partly", TestData.inputs(status: EngineStatus(protection: .partlyProtected(reasons: ["protection.clipboardOff"]),
                                                            weekStats: TestData.week()),
                                       settings: TestData.settings { $0.guardsClipboard = false }, now: TestData.date(10, 5))),
            ("update", TestData.inputs(updateOffer: UpdateOffer(version: "1.1"), now: TestData.date(10, 5))),
            ("update-installing", TestData.inputs(updateOffer: UpdateOffer(version: "1.1", phase: .installing), now: TestData.date(10, 5))),
            ("update-failed", TestData.inputs(updateOffer: UpdateOffer(version: "1.1", phase: .failed(reason: "The downloaded update doesn't match its signed description, so Obscura discarded it.")), now: TestData.date(10, 5))),
            ("burst", TestData.inputs(status: EngineStatus(lastCatch: LastCatch(entryID: card.id, displayName: card.displayName,
                                                                               findings: 1, date: card.createdAt),
                                                           weekStats: TestData.week(today: 3)),
                                      entries: [card, token, undone], lastSeen: TestData.date(9, 30), now: TestData.date(9, 44))),
        ]
    }

    static let thumbnail = NSImage(data: SampleData.terminalPNG(covered: true))

    static func render(_ view: some View, scheme: ColorScheme) -> NSImage? {
        let content = view
            .background(OColor.popover)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var image: NSImage?
        (scheme == .dark ? NSAppearance(named: .darkAqua)! : NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        return image
    }

    static func write(_ image: NSImage, name: String) throws {
        guard let dir = outputDirectory, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @Test func everyStateRendersAtPanelWidthInBothAppearances() throws {
        for (name, inputs) in Self.states() {
            let snapshot = PanelSnapshot.make(inputs)
            var preloaded: [UUID: NSImage] = [:]
            if let id = snapshot.lastCatch?.entryID, let thumb = Self.thumbnail { preloaded[id] = thumb }
            for scheme in [ColorScheme.light, .dark] {
                let view = PanelContent(snapshot: snapshot, perform: { _ in }, loadThumbnail: { _ in nil }, preloaded: preloaded)
                let image = try #require(Self.render(view, scheme: scheme), "\(name) did not render")
                #expect(image.size.width == OMetric.menuBarPanelWidth, "\(name)")
                #expect(image.size.height > 300, "\(name) is only \(image.size.height) pt tall")
                try Self.write(image, name: "panel-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    @Test func thePublicPanelRendersOnSampleData() async throws {
        let model = try await SampleData.model()
        PanelMemory.register(TestData.memory(), for: model)
        for scheme in [ColorScheme.light, .dark] {
            let image = try #require(Self.render(MenuBarPanel(model: model), scheme: scheme))
            #expect(image.size.width == OMetric.menuBarPanelWidth)
            #expect(image.size.height > 300)
            try Self.write(image, name: "public-panel-\(scheme == .dark ? "dark" : "light")")
        }
        model.stop()
    }

    @Test func theMarkRendersInEveryStateAndCarriesTheCount() throws {
        for state in MarkState.allCases {
            let plain = ObscuraMarkDrawing.menuBarImage(state, sweep: 0.25, count: 0)
            #expect(plain.size == CGSize(width: 18, height: 18), "\(state)")
            #expect(plain.isTemplate == !(state == .caught || state == .needsAttention || state == .waiting || state == .focusHolding), "\(state)")
            try Self.write(plain, name: "mark-\(state.rawValue)")
        }
        let badged = ObscuraMarkDrawing.menuBarImage(.protected, sweep: 0, count: 3)
        #expect(badged.size == CGSize(width: ObscuraMarkDrawing.badgedWidth, height: 18))
        #expect(!badged.isTemplate)
        #expect(MarkCopy.accessibilityLabel(.protected, count: 3) == "Obscura: protected, 3 catches to review")
        try Self.write(badged, name: "mark-count")
    }

    /// Every SF Symbol the panel names exists on this system.
    @Test func everySymbolExists() {
        var names: Set<String> = ["lock", "chevron.down"]
        for (_, inputs) in Self.states() {
            let s = PanelSnapshot.make(inputs)
            s.banners.forEach { names.insert($0.symbol) }
            s.lastCatch?.buttons.compactMap(\.symbol).forEach { names.insert($0) }
            s.menu.forEach { if case .row(let r) = $0 { names.insert(r.symbol) } }
        }
        let problems: [Problem] = [Problem(kind: .folderAccess, messageKey: "problem.folder.missing"),
                                   Problem(kind: .ruleCompile, messageKey: "problem.rule.compile"),
                                   Problem(kind: .sourceStart, messageKey: "problem.source.start"),
                                   Problem(kind: .ocrWarmup, messageKey: "problem.warmup.failed")]
        for p in problems { names.insert(ProblemCopy.words(for: p, settings: .default, downloads: TestData.downloads).symbol) }
        names.insert("eye.slash")
        names.insert("play.fill")
        names.insert("arrow.down.circle")
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
        }
    }
}
