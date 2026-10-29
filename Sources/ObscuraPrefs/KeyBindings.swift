import Foundation

/// The person's keyboard shortcuts (G-20): only their changes are stored; every other command has its catalogue
/// default, so a command added in a later version arrives with its default and nobody's file needs a migration.
///
/// Stored as `{command id: chord storage text, or "none" for a cleared shortcut}` under `shortcuts.overrides`.
/// Reading is forgiving: an unknown id (from a newer or older version) is kept but ignored, an unreadable chord falls
/// back to the default, and an override of a fixed command is ignored. Nothing here throws.
public struct KeyBindings: Codable, Sendable, Hashable {
    /// The word stored for a shortcut the person cleared.
    public static let clearedValue = "none"

    /// The raw stored overrides. Kept verbatim (unknown ids included) so a round trip never loses another version's data.
    public private(set) var overrides: [String: String]

    public init(overrides: [String: String] = [:]) { self.overrides = overrides }

    public static let defaults = KeyBindings()

    // MARK: Resolve

    /// The chord the command answers to now: the person's, else the catalogue's default; nil when cleared or none.
    public func chord(for id: ShortcutID) -> KeyChord? {
        switch override(for: id) {
        case .some(.cleared): return nil
        case .some(.chord(let c)): return c
        case nil: return id.command.defaultChord
        }
    }

    /// Every chord that triggers the command: `chord(for:)`, plus the default aliases while it is at its default.
    public func chords(for id: ShortcutID) -> [KeyChord] {
        guard let main = chord(for: id) else { return [] }
        return override(for: id) == nil ? [main] + id.command.defaultAliases : [main]
    }

    /// The command (among `ids`) that `chord` triggers, or nil.
    public func command(matching chord: KeyChord, among ids: [ShortcutID]) -> ShortcutID? {
        ids.first { chords(for: $0).contains(chord) }
    }

    /// The glyph text shown beside a command ("⌥⌘C"), or nil when it has no shortcut.
    public func display(for id: ShortcutID) -> String? { chord(for: id)?.display }

    /// Whether the person changed (or cleared) this command.
    public func isChanged(_ id: ShortcutID) -> Bool { override(for: id) != nil }

    /// How many commands differ from their defaults.
    public var changedCount: Int { ShortcutID.allCases.filter(isChanged).count }

    public enum Override: Equatable, Sendable {
        case chord(KeyChord)
        case cleared
    }

    /// The person's effective override, or nil when the command is at its default (never set, unreadable, a fixed
    /// command, or equal to the default).
    public func override(for id: ShortcutID) -> Override? {
        guard id.command.isChangeable, let raw = overrides[id.rawValue] else { return nil }
        if raw == Self.clearedValue { return id.command.defaultChord == nil ? nil : .cleared }
        guard let chord = KeyChord(storage: raw), chord != id.command.defaultChord else { return nil }
        return .chord(chord)
    }

    // MARK: Change

    /// Sets the command's chord; nil clears it. Setting the default removes the override. A fixed command is untouched.
    public mutating func set(_ chord: KeyChord?, for id: ShortcutID) {
        guard id.command.isChangeable else { return }
        if chord == id.command.defaultChord {
            overrides.removeValue(forKey: id.rawValue)
        } else {
            overrides[id.rawValue] = chord?.storage ?? Self.clearedValue
        }
    }

    /// Back to the default for one command.
    public mutating func reset(_ id: ShortcutID) { overrides.removeValue(forKey: id.rawValue) }

    /// Back to the defaults for every command this version knows. Ids from other versions are dropped too: "Restore
    /// Defaults" means nothing of the person's is left.
    public mutating func resetAll() { overrides.removeAll() }

    // MARK: Codable (a plain dictionary; anything else reads as no overrides)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        overrides = (try? c.decode([String: String].self)) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(overrides)
    }
}

// MARK: - Rules for a new chord

/// Why a chord the person pressed cannot be used.
public enum ShortcutRefusal: Equatable, Sendable {
    /// No ⌘ or ⌃, and not a function key: it would fire while typing.
    case needsCommandOrControl
    /// macOS (or every Mac app) already uses it.
    case reserved(String)
    /// Another Obscura command in an overlapping scope has it.
    case conflict(ShortcutID)
    /// The command cannot be changed.
    case fixed

    /// The inline message under the row.
    public func message(for chord: KeyChord) -> String {
        switch self {
        case .needsCommandOrControl:
            return String(localized: "Use ⌘ or ⌃ with the key (or a function key), so typing never triggers it.")
        case .reserved(let use):
            return String(localized: "\(chord.display) is used by macOS for \(use).")
        case .conflict(let other):
            let o = other.command
            return String(localized: "\(chord.display) is already \(o.title) \(o.scope.place).")
        case .fixed:
            return String(localized: "This shortcut can't be changed.")
        }
    }
}

public enum ShortcutRules {
    /// Chords macOS itself, or every Mac app's standard menus, own. A press of one never reaches Obscura (⌘⇥, ⌘Space,
    /// the screenshot chords) or would take a standard command away from its meaning (⌘Q, ⌘W, ⌘V…).
    public static let reserved: [(chord: KeyChord, use: String)] = {
        let cmd: KeyChord.Modifiers = .command
        func c(_ ch: Character, _ m: KeyChord.Modifiers) -> KeyChord { KeyChord(ch, m) }
        func s(_ sp: KeyChord.Special, _ m: KeyChord.Modifiers) -> KeyChord { KeyChord(.special(sp), m) }
        return [
            (c("q", cmd), String(localized: "Quit")),
            (c("h", cmd), String(localized: "Hide")),
            (c("h", [.option, .command]), String(localized: "Hide Others")),
            (c("m", cmd), String(localized: "Minimize")),
            (c("m", [.option, .command]), String(localized: "Minimize All")),
            (c("w", cmd), String(localized: "Close Window")),
            (c("w", [.option, .command]), String(localized: "Close All")),
            (c("`", cmd), String(localized: "switching windows")),
            (c("`", [.shift, .command]), String(localized: "switching windows")),
            (s(.tab, cmd), String(localized: "switching apps")),
            (s(.tab, [.shift, .command]), String(localized: "switching apps")),
            (s(.space, cmd), String(localized: "Spotlight")),
            (s(.space, [.option, .command]), String(localized: "a Finder search window")),
            (s(.space, .control), String(localized: "switching input sources")),
            (s(.space, [.control, .option]), String(localized: "switching input sources")),
            (s(.space, [.control, .command]), String(localized: "Emoji & Symbols")),
            (s(.escape, [.option, .command]), String(localized: "Force Quit")),
            (c("q", [.control, .command]), String(localized: "Lock Screen")),
            (c("q", [.shift, .command]), String(localized: "Log Out")),
            (c("q", [.option, .shift, .command]), String(localized: "Log Out")),
            (c("d", [.option, .command]), String(localized: "showing the Dock")),
            (c("f", [.control, .command]), String(localized: "full screen")),
            (c("3", [.shift, .command]), String(localized: "screenshots")),
            (c("4", [.shift, .command]), String(localized: "screenshots")),
            (c("5", [.shift, .command]), String(localized: "screenshots")),
            (c("6", [.shift, .command]), String(localized: "screenshots")),
            (c("3", [.control, .shift, .command]), String(localized: "screenshots")),
            (c("4", [.control, .shift, .command]), String(localized: "screenshots")),
            (c("x", cmd), String(localized: "Cut")),
            (c("c", cmd), String(localized: "Copy")),
            (c("v", cmd), String(localized: "Paste")),
            (c("v", [.option, .shift, .command]), String(localized: "Paste and Match Style")),
            (c("a", cmd), String(localized: "Select All")),
            (c("z", cmd), String(localized: "Undo")),
            (c("z", [.shift, .command]), String(localized: "Redo")),
            (c(",", cmd), String(localized: "Settings")),
            (c("?", [.shift, .command]), String(localized: "Help")),
            (c("/", [.shift, .command]), String(localized: "Help")),
        ]
    }()

    /// What macOS uses `chord` for, or nil.
    public static func reservedUse(_ chord: KeyChord) -> String? {
        reserved.first { $0.chord == chord }?.use
    }

    /// Whether `chord` may become `id`'s shortcut, given the other bindings. Nil means it may.
    ///
    /// Order: fixed command, then the modifier rule, then macOS's reserved chords, then Obscura's own commands (a
    /// fixed Obscura chord such as the Journal's ⌘C is caught by the reserved list or the conflict check, whichever
    /// names it better: reserved first, since that is the deeper reason).
    public static func refusal(_ chord: KeyChord, for id: ShortcutID, in bindings: KeyBindings) -> ShortcutRefusal? {
        let command = id.command
        guard command.isChangeable else { return .fixed }
        let isFunction: Bool = if case .special(let s) = chord.key { s.isFunctionKey } else { false }
        if !isFunction && chord.modifiers.isDisjoint(with: [.command, .control]) { return .needsCommandOrControl }
        if let use = reservedUse(chord) { return .reserved(use) }
        for other in ShortcutID.allCases where other != id && other.command.scope.overlaps(command.scope) {
            if bindings.chords(for: other).contains(chord) { return .conflict(other) }
        }
        return nil
    }

    /// Every pair of commands in overlapping scopes that share a chord. Empty for the defaults (tested); a settings
    /// file edited by hand could break it, and the pane shows such a pair.
    public static func conflicts(in bindings: KeyBindings) -> [(ShortcutID, ShortcutID)] {
        var pairs: [(ShortcutID, ShortcutID)] = []
        let ids = ShortcutID.allCases
        for (i, a) in ids.enumerated() {
            for b in ids[(i + 1)...] where a.command.scope.overlaps(b.command.scope) {
                if !Set(bindings.chords(for: a)).isDisjoint(with: bindings.chords(for: b)) { pairs.append((a, b)) }
            }
        }
        return pairs
    }
}
