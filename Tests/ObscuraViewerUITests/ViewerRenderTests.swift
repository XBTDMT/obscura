import Testing
import Foundation
import AppKit
import SwiftUI
@testable import ObscuraViewerUI
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs
import ObscuraTestSupport

/// Hosts a view in an off-screen window (the canvas is AppKit, which ImageRenderer cannot draw), lets its tasks run,
/// and snapshots the content view. Set OBSCURA_VIEWER_RENDER_DIR to also write the PNGs for a visual check.
@MainActor
enum Snapshot {
    static func host<V: View>(_ view: V, width: CGFloat, height: CGFloat = 560, dark: Bool = false,
                              settle: (() -> Void)? = nil) async -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        await spin(host)
        settle?()
        await spin(host)
        return (window, host)
    }

    static func spin(_ view: NSView) async {
        for _ in 0..<12 {
            view.layoutSubtreeIfNeeded()
            pump(0.03)
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// Turns the main run loop briefly so AppKit and SwiftUI flush their updates (synchronous on purpose).
    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Drawn with layer shadows on the side the screen puts them (ObscuraTestSupport.ViewSnapshot), AppKit canvas included.
    static func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        return ViewSnapshot.bitmap(view)
    }

    static func write(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OBSCURA_VIEWER_RENDER_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Distinct colours in a coarse sample: a blank or single-colour render has one or two.
    static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let stepX = max(rep.pixelsWide / 60, 1), stepY = max(rep.pixelsHigh / 60, 1)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let v = (UInt32(c.redComponent * 31) << 10) | (UInt32(c.greenComponent * 31) << 5) | UInt32(c.blueComponent * 31)
                seen.insert(v)
            }
        }
        return seen.count
    }
}

@Suite(.serialized) @MainActor struct ViewerRenderTests {
    @Test func rendersASampleEntryAt720() async throws {
        let model = try await SampleData.model(entries: 6)
        let entry = try #require(model.entries.first { $0.findings.allSatisfy(\.enabled) })
        for dark in [false, true] {
            let (window, host) = await Snapshot.host(ViewerWindow(model: model, entryID: entry.id), width: 720, dark: dark)
            #expect(host.fittingSize.width == OMetric.viewerWidth)
            let rep = try #require(Snapshot.bitmap(host))
            #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
            #expect(Snapshot.distinctColours(rep) > 8, "the canvas, the image and the strip all drew")
            Snapshot.write(rep, dark ? "redacted-dark" : "redacted-light")
            window.close()
        }
    }

    @Test func aFindingLeftVisibleOpensTheInspectorAt880() async throws {
        let model = try await SampleData.model(entries: 6)
        let entry = try #require(model.entries.first { $0.findings.contains { !$0.enabled } })
        let (window, host) = await Snapshot.host(ViewerWindow(model: model, entryID: entry.id), width: 880, dark: true)
        #expect(host.fittingSize.width == OMetric.viewerWidthWithInspector)
        let rep = try #require(Snapshot.bitmap(host))
        Snapshot.write(rep, "left-visible-dark")
        window.close()
    }

    @Test func testShotResultOpensWithItsStoryAt880() async throws {
        let model = try await SampleData.model(entries: 1)
        let entry = try #require(model.entries.first)
        let (window, host) = await Snapshot.host(TestShotResultView(model: model, entryID: entry.id, durationMS: 212), width: 880)
        #expect(host.fittingSize.width == OMetric.viewerWidthWithInspector)
        let rep = try #require(Snapshot.bitmap(host))
        #expect(Snapshot.distinctColours(rep) > 8)
        Snapshot.write(rep, "test-shot-light")
        window.close()
    }

    @Test func originalPeekAndCompareStatesRender() async throws {
        let model = try await SampleData.model(entries: 1)
        let entry = try #require(model.entries.first)
        let cases: [(String, Bool, (ViewerState) -> Void)] = [
            ("original-light", false, { $0.setMode(.original) }),
            ("peek-dark", true, { $0.beginPeek() }),
            ("compare-dark", true, { $0.toggleCompare() }),
            ("zoom-200-light", false, { $0.actualSize(); $0.zoomIn(); $0.zoomIn(); $0.zoomIn() }),
        ]
        for (name, dark, mutate) in cases {
            let state = ViewerState()
            let scene = ViewerScene(model: model, entryID: entry.id, variant: .standard, state: state)
            let (window, host) = await Snapshot.host(scene, width: 720, dark: dark) { mutate(state) }
            #expect(state.loadedRevision == entry.revision)
            let rep = try #require(Snapshot.bitmap(host))
            #expect(Snapshot.distinctColours(rep) > 4)
            Snapshot.write(rep, name)
            window.close()
        }
    }

    @Test func missingEntrySaysSo() async throws {
        let model = try await SampleData.model(entries: 0)
        let (window, host) = await Snapshot.host(ViewerWindow(model: model, entryID: UUID()), width: 720)
        #expect(host.fittingSize.width >= OMetric.viewerWidth)
        window.close()
    }

    /// The toolbar is window chrome (not in the content snapshot); its pieces are rendered on their own.
    @Test func toolbarPiecesRender() async throws {
        for dark in [false, true] {
            let bar = HStack(spacing: 12) {
                TitleBlock(name: "Screenshot 2026-10-26 at 9.41.07 AM.png", subtitle: "4 of 4 secrets blacked out", isLive: false)
                Spacer()
                ToolbarCenter(mode: .original, originalAvailable: true, isPeeking: true) { _ in }
                Spacer()
                ToolbarTrailing(keys: .defaults, zoomLabel: "Fit", zoomEnabled: true, inspectorOn: true, zoomOut: {}, zoomIn: {}, actual: {}, fit: {},
                                copy: {}, toggleInspector: {})
            }
            .padding(.horizontal, 14)
            .frame(width: 880, height: 52)
            .background(OColor.sidebar)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: bar)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size == CGSize(width: 880, height: 52))
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                Snapshot.write(rep, dark ? "toolbar-dark" : "toolbar-light")
            }
            let banner = OriginalBanner().frame(width: 720).environment(\.colorScheme, dark ? .dark : .light)
            if let tiff = ImageRenderer(content: banner).nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                Snapshot.write(rep, dark ? "banner-dark" : "banner-light")
            }
        }
    }
}
