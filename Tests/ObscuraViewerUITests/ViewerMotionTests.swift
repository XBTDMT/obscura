import Testing
import Foundation
import AppKit
import SwiftUI
@testable import ObscuraViewerUI
import ObscuraUIKit
import ObscuraJournal

// Recon B-6 motion fixes in the Viewer (knowledge/recon/motion-2026-10-27/FIXES-in-window.md): T-3, T-4, M-4.
@Suite(.serialized) @MainActor struct ViewerMotionTests {
    /// T-4 / M-4: the inspector is decided from the verdict when the scene is made, before the first frame, so the
    /// window never opens at 720 and grows to 880.
    @Test func theInspectorIsDecidedBeforeTheFirstFrame() async throws {
        let model = try await SampleData.model(entries: 6)
        let left = try #require(model.entries.first { $0.findings.contains { !$0.enabled } })
        let safe = try #require(model.entries.first { $0.findings.allSatisfy(\.enabled) })

        let leftState = ViewerState()
        _ = ViewerScene(model: model, entryID: left.id, variant: .standard, state: leftState)
        #expect(leftState.inspectorChoice == true && leftState.windowWidth == OMetric.viewerWidthWithInspector)

        let safeState = ViewerState()
        _ = ViewerScene(model: model, entryID: safe.id, variant: .standard, state: safeState)
        #expect(safeState.inspectorChoice == false && safeState.windowWidth == OMetric.viewerWidth)

        let shotState = ViewerState()
        _ = ViewerScene(model: model, entryID: safe.id, variant: .testShot(durationMS: 100), state: shotState)
        #expect(shotState.inspectorChoice == true)

        // An entry the model does not have yet is decided when it lands (the task), not here.
        let unknown = ViewerState()
        _ = ViewerScene(model: model, entryID: UUID(), variant: .standard, state: unknown)
        #expect(unknown.inspectorChoice == nil)
    }

    /// M-4: a window created at the scene's default 720 for a catch that needs the inspector is at 880 by the time it
    /// has laid out, with no animated grow (the resize is instant and happens as the view joins the window).
    @Test func aWindowMadeAt720ForALeftVisibleCatchSettlesAt880() async throws {
        let model = try await SampleData.model(entries: 6)
        let left = try #require(model.entries.first { $0.findings.contains { !$0.enabled } })
        let (window, host) = await Snapshot.host(ViewerWindow(model: model, entryID: left.id), width: 720, dark: false)
        #expect(window.frame.width == OMetric.viewerWidthWithInspector)
        let rep = try #require(Snapshot.bitmap(host))
        Snapshot.write(rep, "m4-opened-at-720-settles-880-light")
        window.close()
    }

    /// T-3: the inspector's column and the window's width change together, by exactly the column, in both
    /// directions; the layout minimum never adds a second step (no 1040).
    @Test func theWindowWidthMovesWithTheInspectorByExactlyItsColumn() {
        let at720 = CGRect(x: 100, y: 100, width: 720, height: 560)
        #expect(WindowBox.frame(at720, inspectorShown: true, screen: nil).width == 880)
        let at880 = CGRect(x: 100, y: 100, width: 880, height: 560)
        #expect(WindowBox.frame(at880, inspectorShown: false, screen: nil).width == 720)
        // A window the user widened keeps its canvas width either way.
        let wide = CGRect(x: 0, y: 0, width: 1000, height: 600)
        #expect(WindowBox.frame(wide, inspectorShown: true, screen: nil).width == 1160)
        #expect(WindowBox.frame(CGRect(x: 0, y: 0, width: 1160, height: 600), inspectorShown: false, screen: nil).width == 1000)
        // Never below the layout's minimum.
        #expect(WindowBox.frame(CGRect(x: 0, y: 0, width: 700, height: 560), inspectorShown: false, screen: nil).width == 720)
        // At the screen's right edge the window moves left instead of running off.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let edge = WindowBox.frame(CGRect(x: 700, y: 100, width: 720, height: 560), inspectorShown: true, screen: screen)
        #expect(edge.maxX == screen.maxX && edge.width == 880)
    }

    @Test func theResizeIsInstant() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let box = WindowBox()
        box.window = window
        box.setInspectorShown(true)
        #expect(window.frame.width == 880)           // already there: no animation left to run
        box.setInspectorShown(false)
        #expect(window.frame.width == 720)
        window.close()
    }
}
