import Foundation

/// One keyboard chord: a key plus the modifiers held with it (G-20).
///
/// The key is a *character*, the way macOS menu key equivalents are, never a physical key code: ⌘Z is the key that
/// types "z" on the person's layout (an AZERTY Mac's Z is not where an ANSI Mac's Z is). Letters are stored lower-case
/// and Shift is always an explicit modifier, so ⇧⌘C is `shift+cmd+c`, and a symbol key is stored as the character it
/// types with no modifier (⇧⌘= is `shift+cmd+=`, never `cmd++`). The recorder reads that unmodified character from
/// the event (`NSEvent.characters(byApplyingModifiers: [])`), so ⌥ and ⇧ never change which key was pressed.
///
/// The stored form (`storage`) is plain text, `ctrl+opt+shift+cmd+<key>`, modifiers always in that order.
public struct KeyChord: Hashable, Sendable, Codable, CustomStringConvertible {
    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// A character chord: `KeyChord("c", [.command, .option])`. Letters are lower-cased.
    public init(_ character: Character, _ modifiers: Modifiers = []) {
        self.init(.character(String(character).lowercased()), modifiers)
    }

    // MARK: Key

    public enum Key: Hashable, Sendable {
        /// One printable character, lower-case for letters.
        case character(String)
        case special(Special)
    }

    /// Keys that type no printable character.
    public enum Special: String, Sendable, Hashable, CaseIterable {
        case `return`, tab, space, delete, forwardDelete, escape
        case leftArrow, rightArrow, upArrow, downArrow
        case home, end, pageUp, pageDown, help
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

        public var isFunctionKey: Bool { functionNumber != nil }

        /// 1 for F1 … 20 for F20, nil for every other key.
        public var functionNumber: Int? {
            guard rawValue.first == "f", let n = Int(rawValue.dropFirst()) else { return nil }
            return n
        }

        /// The glyph macOS menus draw for the key.
        var glyph: String {
            switch self {
            case .return: "↩"
            case .tab: "⇥"
            case .space: "Space"
            case .delete: "⌫"
            case .forwardDelete: "⌦"
            case .escape: "Esc"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .home: "↖"
            case .end: "↘"
            case .pageUp: "⇞"
            case .pageDown: "⇟"
            case .help: "Help"
            default: "F\(functionNumber ?? 0)"
            }
        }

        /// What VoiceOver says for the key.
        var spoken: String {
            switch self {
            case .return: String(localized: "Return")
            case .tab: String(localized: "Tab")
            case .space: String(localized: "Space")
            case .delete: String(localized: "Delete")
            case .forwardDelete: String(localized: "Forward Delete")
            case .escape: String(localized: "Escape")
            case .leftArrow: String(localized: "Left Arrow")
            case .rightArrow: String(localized: "Right Arrow")
            case .upArrow: String(localized: "Up Arrow")
            case .downArrow: String(localized: "Down Arrow")
            case .home: String(localized: "Home")
            case .end: String(localized: "End")
            case .pageUp: String(localized: "Page Up")
            case .pageDown: String(localized: "Page Down")
            case .help: String(localized: "Help")
            default: "F\(functionNumber ?? 0)"
            }
        }
    }

    // MARK: Modifiers

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// The HIG order macOS draws them in: ⌃ ⌥ ⇧ ⌘.
        static let ordered: [(Modifiers, token: String, glyph: String)] = [
            (.control, "ctrl", "⌃"), (.option, "opt", "⌥"), (.shift, "shift", "⇧"), (.command, "cmd", "⌘"),
        ]

        var spokenNames: [String] {
            var names: [String] = []
            if contains(.control) { names.append(String(localized: "Control")) }
            if contains(.option) { names.append(String(localized: "Option")) }
            if contains(.shift) { names.append(String(localized: "Shift")) }
            if contains(.command) { names.append(String(localized: "Command")) }
            return names
        }
    }

    // MARK: Text forms

    /// The glyph form macOS menus use: "⌥⌘C", "⌘⌫", "⇧⌘=", "F5". Letters are drawn upper-case; "-" as the minus sign.
    public var display: String {
        let mods = Modifiers.ordered.filter { modifiers.contains($0.0) }.map(\.glyph).joined()
        return mods + keyGlyph
    }

    /// What VoiceOver reads: "Option Command C".
    public var spokenName: String {
        let key: String
        switch self.key {
        case .character(let c): key = Self.spokenCharacter(c)
        case .special(let s): key = s.spoken
        }
        return (modifiers.spokenNames + [key]).joined(separator: " ")
    }

    public var description: String { display }

    private var keyGlyph: String {
        switch key {
        case .character(let c): c == "-" ? "−" : c.uppercased()
        case .special(let s): s.glyph
        }
    }

    private static func spokenCharacter(_ c: String) -> String {
        switch c {
        case ",": String(localized: "Comma")
        case ".": String(localized: "Period")
        case "-": String(localized: "Minus")
        case "=": String(localized: "Equals")
        case "/": String(localized: "Slash")
        case "\\": String(localized: "Backslash")
        case ";": String(localized: "Semicolon")
        case "'": String(localized: "Quote")
        case "`": String(localized: "Grave Accent")
        case "[": String(localized: "Left Bracket")
        case "]": String(localized: "Right Bracket")
        default: c.uppercased()
        }
    }

    /// The stored form: `ctrl+opt+shift+cmd+<key>`, where `<key>` is the character or a `Special` raw value.
    /// A character key that could read as a special name or contains "+" is stored as `char:<c>`.
    public var storage: String {
        let mods = Modifiers.ordered.filter { modifiers.contains($0.0) }.map(\.token)
        let keyText: String
        switch key {
        case .character(let c):
            keyText = (c.count == 1 && c != "+" && Special(rawValue: c) == nil) ? c : "char:\(c)"
        case .special(let s):
            keyText = s.rawValue
        }
        return (mods + [keyText]).joined(separator: "+")
    }

    /// Parses `storage`. Nil for anything malformed: an unknown modifier, a repeated one, no key, an empty key.
    public init?(storage text: String) {
        var rest = Substring(text)
        var mods: Modifiers = []
        // Modifier tokens first, each followed by "+"; whatever is left is the key (which may itself be "+"-free text).
        while let plus = rest.firstIndex(of: "+") {
            let token = rest[..<plus]
            guard let m = Modifiers.ordered.first(where: { $0.token == token })?.0, !mods.contains(m) else { break }
            mods.insert(m)
            rest = rest[rest.index(after: plus)...]
        }
        let keyText = String(rest)
        if keyText.hasPrefix("char:") {
            let c = String(keyText.dropFirst(5))
            guard c.count == 1 else { return nil }
            self.init(.character(c.lowercased()), mods)
        } else if let s = Special(rawValue: keyText) {
            self.init(.special(s), mods)
        } else {
            guard keyText.count == 1, keyText != "+" else { return nil }
            self.init(.character(keyText.lowercased()), mods)
        }
    }

    // Codable as the stored text, so a document reads the same as the defaults domain.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let chord = KeyChord(storage: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a key chord"))
        }
        self = chord
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(storage)
    }
}

// MARK: - From a key press

extension KeyChord {
    /// The macOS virtual key codes of the keys that type no printable character (Carbon `kVK_*`; layout-independent).
    static let specialKeyCodes: [UInt16: Special] = [
        36: .return, 76: .return, 48: .tab, 49: .space, 51: .delete, 117: .forwardDelete, 53: .escape,
        123: .leftArrow, 124: .rightArrow, 126: .upArrow, 125: .downArrow,
        115: .home, 119: .end, 116: .pageUp, 121: .pageDown, 114: .help,
        122: .f1, 120: .f2, 99: .f3, 118: .f4, 96: .f5, 97: .f6, 98: .f7, 100: .f8, 101: .f9, 109: .f10,
        103: .f11, 111: .f12, 105: .f13, 107: .f14, 113: .f15, 106: .f16, 64: .f17, 79: .f18, 80: .f19, 90: .f20,
    ]

    /// The chord a key press means. Pure, so the recorder and every key handler are tested without events.
    ///
    /// - Parameters:
    ///   - keyCode: the event's virtual key code; decides the keys that type no character.
    ///   - baseCharacters: what the key types with no modifier held (`characters(byApplyingModifiers: [])`).
    ///   - modifiers: the four modifiers held; Caps Lock, Fn and the keypad flag are not part of a chord.
    /// - Returns: nil for a press that is only a modifier, or one whose character cannot be a key equivalent.
    public static func from(keyCode: UInt16, baseCharacters: String?, modifiers: Modifiers) -> KeyChord? {
        if let special = specialKeyCodes[keyCode] { return KeyChord(.special(special), modifiers) }
        guard let text = baseCharacters, text.count == 1, let scalar = text.unicodeScalars.first else { return nil }
        // Control characters and the private-use range AppKit uses for function keys are not printable keys.
        if scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value) { return nil }
        if text == " " { return KeyChord(.special(.space), modifiers) }
        return KeyChord(.character(text.lowercased()), modifiers)
    }
}
