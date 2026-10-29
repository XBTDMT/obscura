// The viewer's keyboard: Tab switches, Space compares, Esc closes, ⌘C copies, zoom, the inspector — each command's
// chord comes from the person's bindings (G-20; defaults in `ShortcutCatalogue`). A window-scoped local event monitor,
// because Tab and Space must work whatever has focus (SwiftUI's Tab moves focus). It also hands the view its NSWindow,
// for Close and for growing the window when the inspector opens.
import SwiftUI
import AppKit
import ObscuraUIKit
import ObscuraPrefs

enum ViewerKey: Equatable, Sendable, CaseIterable {
    case toggleMode, compare, escape, copy, zoomIn, zoomOut, actualSize, fit, inspector

    /// The catalogue command behind each key.
    var shortcut: ShortcutID {
        switch self {
        case .toggleMode: .viewerToggleMode
        case .compare: .viewerCompare
        case .escape: .viewerClose
        case .copy: .viewerCopy
        case .zoomIn: .viewerZoomIn
        case .zoomOut: .viewerZoomOut
        case .actualSize: .viewerActualSize
        case .fit: .viewerZoomToFit
        case .inspector: .viewerFindings
        }
    }

    /// The command a chord means under `bindings`, or nil. Pure, so the shortcut table is tested without events.
    static func command(_ chord: KeyChord, bindings: KeyBindings) -> ViewerKey? {
        guard let id = bindings.command(matching: chord, among: allCases.map(\.shortcut)) else { return nil }
        return allCases.first { $0.shortcut == id }
    }

    /// The command a key press means: the press as a chord (`KeyChord.from`), then `command(_:bindings:)`.
    static func command(keyCode: UInt16, baseCharacters: String?, flags: NSEvent.ModifierFlags,
                        bindings: KeyBindings) -> ViewerKey? {
        guard let chord = KeyChord.from(keyCode: keyCode, baseCharacters: baseCharacters, modifiers: .init(flags)) else { return nil }
        return command(chord, bindings: bindings)
    }
}

/// A zero-size view that watches key presses for its own window only.
struct WindowKeyHandler: NSViewRepresentable {
    /// Read at each key press, so a change in Settings applies to an open Viewer at once.
    var bindings: @MainActor () -> KeyBindings
    var handle: @MainActor (ViewerKey) -> Bool
    var windowChanged: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> KeyMonitorView {
        let v = KeyMonitorView()
        v.bindings = bindings
        v.handle = handle
        v.windowChanged = windowChanged
        return v
    }

    func updateNSView(_ v: KeyMonitorView, context: Context) {
        v.bindings = bindings
        v.handle = handle
        v.windowChanged = windowChanged
    }

    static func dismantleNSView(_ v: KeyMonitorView, coordinator: ()) { v.removeMonitor() }
}

final class KeyMonitorView: NSView {
    var bindings: (@MainActor () -> KeyBindings)?
    var handle: (@MainActor (ViewerKey) -> Bool)?
    var windowChanged: (@MainActor (NSWindow?) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        windowChanged?(window)
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Read what the handler needs here; only Sendable values cross into the main-actor check.
            // The unmodified character, so ⌥ and ⇧ never change which key was pressed (⌥I types "ˆ").
            let keyCode = event.keyCode, characters = event.characters(byApplyingModifiers: []), flags = event.modifierFlags
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, windowNumber == window.windowNumber, window.isKeyWindow,
                      let key = ViewerKey.command(keyCode: keyCode, baseCharacters: characters, flags: flags,
                                                  bindings: self.bindings?() ?? .defaults) else { return false }
                return self.handle?(key) == true
            }
            return handled ? nil : event
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The hosting window, held without making SwiftUI re-render.
@MainActor
final class WindowBox {
    weak var window: NSWindow?

    /// Widens the window by the inspector's column when it opens (720 → 880) and narrows it back when it closes,
    /// keeping its left edge, so the canvas keeps its width. Instant: see `ViewerScene.setInspector`.
    func setInspectorShown(_ shown: Bool) {
        guard let window else { return }
        let frame = Self.frame(window.frame, inspectorShown: shown, screen: window.screen?.visibleFrame)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    /// Makes the window at least `width` wide, at once (used before it is on screen).
    func ensureWidth(atLeast width: CGFloat) {
        guard let window, window.frame.width < width else { return }
        var frame = window.frame
        frame.size.width = width
        window.setFrame(Self.keepOnScreen(frame, window.screen?.visibleFrame), display: true, animate: false)
    }

    func close() { window?.performClose(nil) }

    /// The window frame after the inspector opens or closes: ± the column's width (system.html "Widths": 720, 880
    /// with the inspector), never narrower than the layout's minimum, moved left when it would run off the screen.
    static func frame(_ frame: CGRect, inspectorShown shown: Bool, screen: CGRect?) -> CGRect {
        let column = OMetric.viewerWidthWithInspector - OMetric.viewerWidth
        var result = frame
        result.size.width = shown ? max(frame.width + column, OMetric.viewerWidthWithInspector)
                                  : max(frame.width - column, OMetric.viewerWidth)
        return keepOnScreen(result, screen)
    }

    static func keepOnScreen(_ frame: CGRect, _ screen: CGRect?) -> CGRect {
        var result = frame
        if let screen, result.maxX > screen.maxX { result.origin.x = max(screen.minX, screen.maxX - result.width) }
        return result
    }
}
