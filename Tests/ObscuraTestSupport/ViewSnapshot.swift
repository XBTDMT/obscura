// ViewSnapshot: draws an NSHostingView (SwiftUI with AppKit views inside) off screen the way the window server shows
// it, layer shadows included.
//
// Why not `NSView.cacheDisplay(in:to:)`: it draws through a flipped CGContext, and a Core Graphics shadow offset is
// given in the context's base space, which a flipped transform does not turn over, so every layer shadow lands on the
// wrong side (measured 2026-10-27: a `y: 3` drop under a shape spanning rows 10–33 drew at rows 7–9 above it;
// `ImageRenderer` drew it at 34–36 below). `ImageRenderer` cannot be used instead because it does not draw AppKit views
// (the Viewer canvas, segmented pickers, search fields).
//
// What this does: renders the view's layer tree with `CALayer.render(in:)` into a plain y-up bitmap context with no
// flipping transform. The hosting layer is geometry-flipped, so the picture comes out mirrored top-to-bottom with every
// shadow mirrored along with it; turning the finished bitmap over (an image copy, no shadow involved) gives the screen
// picture with each shadow on the side the screen draws it. `ViewSnapshotTests` keeps that proof in the suite.
public import AppKit
import QuartzCore

@MainActor
public enum ViewSnapshot {
    /// The view as the screen shows it, at its window's backing scale (2× when there is no window). Lays the view out,
    /// displays it and commits the layer tree first: without the flush an AppKit view's draw(_:) has not reached its
    /// layer yet and renders blank (ViewSnapshotTests.appKitDrawnViewsAreDrawnTheRightWayUp read white there).
    public static func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.display()
        CATransaction.flush()
        // Only the measured case: a geometry-flipped layer (every NSHostingView's). Anything else returns nil, which the
        // callers' #require turns into a failure instead of a picture of unproven orientation.
        guard let layer = view.layer, layer.isGeometryFlipped else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int((view.bounds.width * scale).rounded()), height = Int((view.bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let space = view.window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        func context() -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let drawn = context(), let upright = context() else { return nil }
        drawn.scaleBy(x: scale, y: scale)
        layer.render(in: drawn)
        guard let mirrored = drawn.makeImage() else { return nil }
        upright.translateBy(x: 0, y: CGFloat(height))
        upright.scaleBy(x: 1, y: -1)
        upright.draw(mirrored, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = upright.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = view.bounds.size
        return rep
    }
}
