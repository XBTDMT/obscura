// ViewSnapshot (ObscuraTestSupport), the renderer behind the Journal, Viewer and Settings render tests, draws a layer
// shadow on the side the screen does and still draws AppKit views (redman 2026-10-27: NSView.cacheDisplay put a `y: 3`
// drop above its shape). SwiftUI's ImageRenderer is the reference for the shadow; it cannot draw AppKit views.
import Testing
import AppKit
import SwiftUI
import ObscuraTestSupport

/// An AppKit view that paints itself blue in draw(_:), as the Viewer canvas paints the screenshot.
private final class BlueView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
        bounds.fill()
    }
}

private struct BlueRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> BlueView { BlueView() }
    func updateNSView(_ nsView: BlueView, context: Context) {}
}

@MainActor
@Suite struct ViewSnapshotTests {
    static let size = CGSize(width: 180, height: 60)

    /// A black 30 × 24 pt shape at y 10–34 with a hard 50 % shadow 3 pt down, and an AppKit-drawn blue square.
    static func probe(appKit: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Rectangle().fill(Color.black).frame(width: 30, height: 24)
                .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: 3)
                .offset(x: 15, y: 10)
            if appKit { BlueRepresentable().frame(width: 20, height: 20).offset(x: 120, y: 20) }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Point rows (top = 0) down the shape's middle column that are black (the shape) and mid-grey (its shadow).
    static func rows(_ rep: NSBitmapImageRep) -> (shape: [Int], shadow: [Int]) {
        let scale = CGFloat(rep.pixelsWide) / size.width
        var shape: [Int] = [], shadow: [Int] = []
        for y in 0..<Int(size.height) {
            guard let c = rep.colorAt(x: Int(30 * scale), y: Int((CGFloat(y) + 0.5) * scale))?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent < 0.1 { shape.append(y) } else if c.redComponent < 0.9 { shadow.append(y) }
        }
        return (shape, shadow)
    }

    static func viewSnapshot(_ view: some View) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return try #require(ViewSnapshot.bitmap(host))
    }

    @Test func aDropShadowFallsBelowItsShapeAsImageRendererDrawsIt() throws {
        let renderer = ImageRenderer(content: Self.probe(appKit: false))
        renderer.scale = 2
        let reference = Self.rows(NSBitmapImageRep(cgImage: try #require(renderer.cgImage)))
        #expect(reference.shape == Array(10...33))
        #expect(reference.shadow == [34, 35, 36], "the reference itself: 3 pt below the shape")

        let snapshot = Self.rows(try Self.viewSnapshot(Self.probe(appKit: false)))
        #expect(snapshot.shape == reference.shape)
        #expect(!snapshot.shadow.isEmpty && snapshot.shadow.allSatisfy { $0 > 33 }, "shadow rows \(snapshot.shadow) are below the shape")
        #expect(Set(snapshot.shadow).isSubset(of: Set(reference.shadow)))
    }

    @Test func appKitDrawnViewsAreDrawnTheRightWayUp() throws {
        let rep = try Self.viewSnapshot(Self.probe(appKit: true))
        let scale = CGFloat(rep.pixelsWide) / Self.size.width
        func colour(_ x: CGFloat, _ y: CGFloat) -> NSColor? { rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) }
        let inside = try #require(colour(130, 30))
        #expect(inside.blueComponent > 0.9 && inside.redComponent < 0.1, "the AppKit view is drawn: \(inside)")
        let above = try #require(colour(130, 15)), below = try #require(colour(130, 45))
        #expect(above.redComponent > 0.9 && below.redComponent > 0.9, "and only at y 20–40, not mirrored")
        #expect(Self.rows(rep).shape == Array(10...33), "the SwiftUI shape is the right way up beside it")
    }
}
