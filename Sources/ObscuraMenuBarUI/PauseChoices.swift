// When the panel's pause choices (For 15 Minutes · For 1 Hour · Until Tomorrow · Until I Resume) open and close
// (G-19 M-15a, ruled 2026-10-27: open on hover by default, a setting for click only). Pure, so every rule is a
// unit test; `PauseRow` in PanelContent.swift carries it out. The pop is drawn inside the panel under the row
// (menubar.html "The Pause duration pop", `.submenu`), so it opens and closes with the panel's one motion: instantly.
import Foundation
import ObscuraPrefs

struct PauseChoicesPresentation: Equatable, Sendable {
    /// How the choices open (`Settings.pauseChoicesOpen`).
    var trigger: PauseChoicesTrigger
    private(set) var isOpen = false
    private(set) var rowHovered = false
    private(set) var popHovered = false

    /// How long the pointer may be outside both the row and the pop before a hover-opened pop closes, so a pointer
    /// crossing the seam between them, or overshooting by a few points, does not flicker it shut (a Mac submenu waits
    /// a moment the same way).
    static let leaveGrace: Duration = .milliseconds(300)

    init(trigger: PauseChoicesTrigger) { self.trigger = trigger }

    /// The pointer entered or left the Pause Protection row. Entering opens the choices in hover mode; picking still
    /// takes a click, so a stray hover never pauses anything. Returns true when the caller should wait
    /// `leaveGrace` and then call `graceEnded()`.
    @discardableResult
    mutating func rowHover(_ inside: Bool) -> Bool {
        rowHovered = inside
        if inside, trigger == .hover { isOpen = true }
        return needsGrace
    }

    /// The pointer entered or left the pop itself. Returns true when the caller should wait and call `graceEnded()`.
    @discardableResult
    mutating func popHover(_ inside: Bool) -> Bool {
        popHovered = inside
        return needsGrace
    }

    /// A click (or Return / Space) on the row: opens or closes the choices in either mode.
    mutating func rowClicked() { isOpen.toggle() }

    /// The grace after the pointer left ran out: in hover mode the pop closes unless the pointer came back.
    mutating func graceEnded() {
        if needsGrace { isOpen = false }
    }

    /// A choice was picked: the pop closes (the pause itself is the panel action).
    mutating func chose() { isOpen = false }

    /// Escape: closes the pop first. Returns true when it did, so the panel stays open for a second Escape.
    mutating func escape() -> Bool {
        guard isOpen else { return false }
        isOpen = false
        return true
    }

    /// The panel closed, or the trigger setting changed: start closed.
    mutating func reset(trigger: PauseChoicesTrigger) {
        self = PauseChoicesPresentation(trigger: trigger)
    }

    /// A hover-mode pop with the pointer outside both the row and the pop is waiting to close.
    private var needsGrace: Bool { trigger == .hover && isOpen && !rowHovered && !popHovered }
}
