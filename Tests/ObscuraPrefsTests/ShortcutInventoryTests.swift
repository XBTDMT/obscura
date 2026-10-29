import Foundation
import Testing
@testable import ObscuraPrefs

/// G-20's guarantee, checked against the source tree: every shortcut is a catalogue command read through the resolver.
/// A `.keyboardShortcut("x")`, a menu item with a key equivalent, a key handler reading raw characters, or a chord
/// glyph naming an Obscura command written into a string anywhere but the catalogue fails here.
@Suite struct ShortcutInventoryTests {
    /// The repository root: this file is Tests/ObscuraPrefsTests/ShortcutInventoryTests.swift.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The files allowed to spell chords: the catalogue and its model (ObscuraPrefs) and the one SwiftUI/AppKit adapter.
    static let resolverFiles: Set<String> = [
        "Sources/ObscuraPrefs/ShortcutCatalogue.swift",
        "Sources/ObscuraPrefs/KeyBindings.swift",
        "Sources/ObscuraPrefs/KeyChord.swift",
        "Sources/ObscuraUIKit/Shortcuts.swift",
    ]

    struct SourceLine { var file: String; var number: Int; var text: String }

    /// Every non-comment line of every Swift file the app is built from (the packages' sources and the app target).
    static let lines: [SourceLine] = {
        var out: [SourceLine] = []
        let fm = FileManager.default
        for dir in ["Sources", "Apps"] {
            let base = root.appendingPathComponent(dir)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let rel = String(url.path.dropFirst(root.path.count + 1))
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    out.append(SourceLine(file: rel, number: i + 1, text: line))
                }
            }
        }
        return out
    }()

    static var outsideResolver: [SourceLine] { lines.filter { !resolverFiles.contains($0.file) } }

    @Test func theTreeWasFound() {
        // A guard against a silent pass: the walk must see the app's own sources.
        #expect(Self.lines.count > 5_000)
        #expect(Self.lines.contains { $0.file == "Apps/Obscura/ObscuraApp.swift" })
        #expect(Self.lines.contains { $0.file == "Sources/ObscuraUIKit/Shortcuts.swift" })
    }

    @Test func noKeyboardShortcutOutsideTheResolver() {
        // Return and Esc as a sheet's default and cancel buttons are button roles, not commands (catalogue header).
        let roles = ["keyboardShortcut(.defaultAction)", "keyboardShortcut(.cancelAction)"]
        for line in Self.outsideResolver where line.text.contains("keyboardShortcut(") {
            var rest = line.text
            for role in roles { rest = rest.replacingOccurrences(of: role, with: "") }
            #expect(!rest.contains("keyboardShortcut("), "\(line.file):\(line.number) sets a shortcut outside the catalogue")
        }
    }

    @Test func noMenuItemKeyEquivalentOutsideTheResolver() {
        for line in Self.outsideResolver where line.text.contains("keyEquivalent:") {
            #expect(line.text.contains(#"keyEquivalent: """#), "\(line.file):\(line.number) gives a menu item a key equivalent")
        }
    }

    @Test func keyHandlersReadChordsNotRawCharacters() {
        // `charactersIgnoringModifiers` changes with ⌥ (⌥I is "ˆ"); handlers go through `KeyChord.from`.
        for line in Self.outsideResolver {
            #expect(!line.text.contains("charactersIgnoringModifiers"), "\(line.file):\(line.number)")
            #expect(!line.text.contains("keyCode =="), "\(line.file):\(line.number) compares a key code")
        }
        // SwiftUI key presses are only the arrows and Return of a list, grid or sidebar (navigation, not commands).
        let navigation = [".upArrow", ".downArrow", ".leftArrow", ".rightArrow", ".return"]
        for line in Self.outsideResolver where line.text.contains(".onKeyPress(") {
            let arg = line.text.components(separatedBy: ".onKeyPress(").dropFirst().map { String($0.prefix(12)) }
            #expect(arg.allSatisfy { a in navigation.contains { a.hasPrefix($0) } }, "\(line.file):\(line.number)")
        }
    }

    /// Text inside double quotes on a line.
    static func stringLiterals(_ line: String) -> [String] {
        var out: [String] = []
        var current: String?
        var escaped = false
        for ch in line {
            if var c = current {
                if escaped { c.append(ch); escaped = false; current = c; continue }
                if ch == "\\" { escaped = true; c.append(ch); current = c; continue }
                if ch == "\"" { out.append(c); current = nil; continue }
                c.append(ch); current = c
            } else if ch == "\"" {
                current = ""
            }
        }
        return out
    }

    /// The chords written as glyphs in a text ("⇧⌘5 ▸ Options" → ⇧⌘5).
    static func glyphChords(_ text: String) -> [KeyChord] {
        let glyphs: [Character: KeyChord.Modifiers] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        var out: [KeyChord] = []
        var mods: KeyChord.Modifiers = []
        for ch in text {
            if let m = glyphs[ch] { mods.insert(m); continue }
            if !mods.isEmpty { out.append(KeyChord(ch, mods)); mods = [] }
        }
        return out
    }

    @Test func chordGlyphsInTextNameOnlyMacOSShortcuts() {
        // Words may name macOS's own chords ("the Screenshot app (⇧⌘5)", "⌘V in Slack"); an Obscura command's chord
        // is always read from the bindings so it follows the person's change.
        var seen = 0
        for line in Self.outsideResolver {
            for literal in Self.stringLiterals(line.text) {
                for chord in Self.glyphChords(literal) {
                    seen += 1
                    #expect(ShortcutRules.reservedUse(chord) != nil,
                            "\(line.file):\(line.number) writes \(chord.display), which is not a macOS shortcut")
                }
            }
        }
        #expect(seen > 0)  // the Protection pane's screenshot and clipboard lines are seen
    }

    @Test func theGlyphReaderWorks() {
        #expect(Self.glyphChords("Copy Original (⌥⌘C)") == [KeyChord("c", [.option, .command])])
        #expect(Self.glyphChords("the Screenshot app (⇧⌘5 ▸ Options) and ⌘V") == [KeyChord("5", [.shift, .command]), KeyChord("v", .command)])
        #expect(Self.stringLiterals(#"Text("a \"b\" ⌘O"), x: "y""#) == [#"a \"b\" ⌘O"#, "y"])
    }

    @Test func everyCatalogueCommandIsUsedByASurface() {
        // An id that no surface reads is a command the person can rebind to no effect.
        let surfaces = Self.lines.filter { !$0.file.hasPrefix("Sources/ObscuraPrefs/") }
        for id in ShortcutID.allCases {
            let name = String(describing: id)
            #expect(surfaces.contains { $0.text.contains(".\(name)") }, "\(id.rawValue) (.\(name)) is never read")
        }
    }
}
