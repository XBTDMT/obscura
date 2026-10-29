import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraViewerUI

/// G-19 in the Viewer: the wipe compare (#15) and the Original banner over the picture (T-12).
@Suite struct WipeGeometryTests {
    @Test func positionsAreClampedToThePicture() {
        #expect(WipeGeometry.clamp(-0.4) == 0)
        #expect(WipeGeometry.clamp(1.7) == 1)
        #expect(WipeGeometry.clamp(0.25) == 0.25)
        #expect(WipeGeometry.clamp(.nan) == WipeGeometry.start)
        #expect(WipeGeometry.clamp(.infinity) == WipeGeometry.start)
    }

    @Test func aPointerMapsToThePictureAndHoldsAtItsEdges() {
        let picture = CGRect(x: 100, y: 20, width: 400, height: 200)
        #expect(WipeGeometry.position(forX: 300, in: picture) == 0.5)
        #expect(WipeGeometry.position(forX: 100, in: picture) == 0)
        #expect(WipeGeometry.position(forX: 40, in: picture) == 0, "dragging past the left edge holds at the edge")
        #expect(WipeGeometry.position(forX: 900, in: picture) == 1, "and past the right edge")
        #expect(WipeGeometry.position(forX: 200, in: .zero) == WipeGeometry.start, "no picture yet: the middle")
        #expect(WipeGeometry.dividerX(0.25, in: picture) == 200)
        #expect(WipeGeometry.dividerX(3, in: picture) == 500)
    }

    @Test func thePictureFitsAndCentres() {
        let container = CGRect(x: 10, y: 18, width: 700, height: 400)
        let wide = WipeGeometry.fittedRect(imageSize: CGSize(width: 1400, height: 400), in: container)
        #expect(wide == CGRect(x: 10, y: 118, width: 700, height: 200))
        let tall = WipeGeometry.fittedRect(imageSize: CGSize(width: 200, height: 800), in: container)
        #expect(tall == CGRect(x: 310, y: 18, width: 100, height: 400))
        #expect(WipeGeometry.fittedRect(imageSize: .zero, in: container).width == 0)
    }
}

@Suite @MainActor struct WipeStateTests {
    @Test func compareStartsInTheMiddleAndTheDividerStaysOnThePicture() {
        let s = ViewerState()
        s.install(clean: NSImage(size: NSSize(width: 40, height: 20)), original: NSImage(size: NSSize(width: 40, height: 20)), revision: 1)
        s.toggleCompare()
        #expect(s.isComparing && s.wipePosition == WipeGeometry.start)
        s.setWipePosition(1.4)
        #expect(s.wipePosition == 1)
        s.setWipePosition(0.3)
        s.toggleCompare(); s.toggleCompare()
        #expect(s.wipePosition == WipeGeometry.start, "a new compare starts in the middle again")
        #expect(Settings.default.compareStyle == .sideBySide)
    }
}

@Suite(.serialized) @MainActor struct G19ViewerRenderTests {
    /// The canvas's scroll view, in window coordinates.
    static func canvasFrame(_ host: NSView) -> CGRect? {
        func find(_ view: NSView) -> NSView? {
            if view is ZoomingScrollView { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return find(host).map { $0.convert($0.bounds, to: nil) }
    }

    /// T-12: Tab to the original shows the red banner over the picture; the canvas keeps its frame, so a fitted image
    /// does not shrink and grow on every Tab.
    @Test func tabToTheOriginalDoesNotMoveTheCanvas() async throws {
        let model = try await SampleData.model(entries: 1)
        let entry = try #require(model.entries.first)
        let state = ViewerState()
        let (window, host) = await Snapshot.host(ViewerScene(model: model, entryID: entry.id, variant: .standard, state: state), width: 720)
        defer { window.close() }
        let redacted = try #require(Self.canvasFrame(host))
        state.setMode(.original)
        await Snapshot.spin(host)
        #expect(state.mode == .original)
        let original = try #require(Self.canvasFrame(host))
        #expect(original == redacted, "the banner floats over the picture: \(original) vs \(redacted)")
    }

    @Test func theWipeCompareRendersAndDiffersFromSideBySide() async throws {
        var bitmaps: [CompareStyle: NSBitmapImageRep] = [:]
        for style in CompareStyle.allCases {
            var settings = Settings.default
            settings.compareStyle = style
            let model = try await SampleData.model(entries: 1, settings: settings)
            let entry = try #require(model.entries.first)
            let state = ViewerState()
            let (window, host) = await Snapshot.host(ViewerScene(model: model, entryID: entry.id, variant: .standard, state: state),
                                                     width: 720) { state.toggleCompare() }
            #expect(state.isComparing)
            let rep = try #require(Snapshot.bitmap(host))
            #expect(Snapshot.distinctColours(rep) > 4)
            Snapshot.write(rep, "compare-\(style.rawValue)")
            bitmaps[style] = rep
            window.close()
        }
        let side = try #require(bitmaps[.sideBySide]?.tiffRepresentation)
        let wipe = try #require(bitmaps[.wipe]?.tiffRepresentation)
        #expect(side != wipe, "the setting changes what compare draws")
    }
}
