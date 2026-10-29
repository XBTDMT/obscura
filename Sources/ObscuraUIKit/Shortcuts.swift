// The one place a keyboard shortcut reaches SwiftUI or AppKit (G-20). Every surface asks `KeyBindings` (catalogue
// default + the person's change, `ObscuraPrefs`) for a command's chord and applies it through `shortcut(_:_:)` or
// matches a key press with `KeyChord.from(event:)`; ShortcutInventoryTests fails on a chord written anywhere else.
public import SwiftUI
public import AppKit
public import ObscuraPrefs

extension KeyChord.Modifiers {
    /// The chord modifiers of an AppKit event (Caps Lock, Fn and the keypad flag are not part of a chord).
    public init(_ flags: NSEvent.ModifierFlags) {
        var m: KeyChord.Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if contains(.control) { m.insert(.control) }
        if contains(.option) { m.insert(.option) }
        if contains(.shift) { m.insert(.shift) }
        if contains(.command) { m.insert(.command) }
        return m
    }
}

extension KeyChord {
    /// The chord of a key-down event: its key by key code for keys that type nothing, else the character the key types
    /// with no modifier held (so ⌥ and ⇧ never change which key it was).
    @MainActor public static func from(event: NSEvent) -> KeyChord? {
        guard event.type == .keyDown else { return nil }
        return from(keyCode: event.keyCode, baseCharacters: event.characters(byApplyingModifiers: []),
                    modifiers: Modifiers(event.modifierFlags))
    }

    /// The SwiftUI form, for buttons and menu commands.
    public var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: modifiers.eventModifiers)
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let c): return KeyEquivalent(Character(c))
        case .special(let s):
            switch s {
            case .return: return .return
            case .tab: return .tab
            case .space: return .space
            case .delete: return .delete
            case .forwardDelete: return .deleteForward
            case .escape: return .escape
            case .leftArrow: return .leftArrow
            case .rightArrow: return .rightArrow
            case .upArrow: return .upArrow
            case .downArrow: return .downArrow
            case .home: return .home
            case .end: return .end
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            case .help: return KeyEquivalent(Character(UnicodeScalar(UInt32(NSHelpFunctionKey))!))
            default:
                // F1…F20 are AppKit's private-use function-key characters, consecutive from NSF1FunctionKey.
                let n = UInt32(NSF1FunctionKey) + UInt32((s.functionNumber ?? 1) - 1)
                return KeyEquivalent(Character(UnicodeScalar(n)!))
            }
        }
    }
}

extension View {
    /// Gives this button (or menu command) the command's current shortcut, or none when the person cleared it.
    /// Reading `bindings` from the model's settings keeps it live: a change in Settings re-renders the button.
    public func shortcut(_ id: ShortcutID, _ bindings: KeyBindings) -> some View {
        keyboardShortcut(bindings.chord(for: id)?.keyboardShortcut)
    }

    /// Gives this button a chord already resolved from the bindings (a value a snapshot carries), or none.
    public func shortcut(_ chord: KeyChord?) -> some View {
        keyboardShortcut(chord?.keyboardShortcut)
    }
}

/// Text that names a command's shortcut, so tooltips and labels follow the person's bindings.
public enum ShortcutText {
    /// "Zoom in (⌘=)", or just "Zoom in" when the command has no shortcut.
    public static func withChord(_ title: String, _ id: ShortcutID, _ bindings: KeyBindings) -> String {
        guard let chord = bindings.display(for: id) else { return title }
        return "\(title) (\(chord))"
    }

    /// "Undo ⌘Z", or just "Undo".
    public static func trailing(_ title: String, _ id: ShortcutID, _ bindings: KeyBindings) -> String {
        guard let chord = bindings.display(for: id) else { return title }
        return "\(title) \(chord)"
    }
}
