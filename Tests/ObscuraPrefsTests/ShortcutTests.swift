import Foundation
import Testing
import ObscuraTestSupport
@testable import ObscuraPrefs

// G-20: the catalogue, the resolver, the rules for a new chord, the stored form, and key-press parsing.

@Suite struct ShortcutCatalogueTests {
    @Test func everyCommandIsCataloguedOnceWithATitle() {
        #expect(ShortcutCatalogue.all.map(\.id) == ShortcutID.allCases)
        #expect(Set(ShortcutCatalogue.all.map(\.id)).count == ShortcutID.allCases.count)
        for c in ShortcutCatalogue.all { #expect(!c.title.isEmpty, "\(c.id)") }
        // Every scope is shown as a group, and every command sits in one.
        #expect(Set(ShortcutCatalogue.groups) == Set(ShortcutScope.allCases))
        #expect(ShortcutCatalogue.groups.flatMap { ShortcutCatalogue.commands(in: $0) }.count == ShortcutID.allCases.count)
    }

    @Test func everyCommandHasADefault() {
        // G-19 #20: "We should have default."
        for c in ShortcutCatalogue.all { #expect(c.defaultChord != nil, "\(c.id)") }
    }

    @Test func defaultsAreUniqueWhereScopesOverlap() {
        #expect(ShortcutRules.conflicts(in: .defaults).isEmpty)
        // And the same check by hand, aliases included.
        let all = ShortcutCatalogue.all
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] where a.scope.overlaps(b.scope) {
                let ca = Set([a.defaultChord].compactMap { $0 } + a.defaultAliases)
                let cb = Set([b.defaultChord].compactMap { $0 } + b.defaultAliases)
                #expect(ca.isDisjoint(with: cb), "\(a.id) and \(b.id)")
            }
        }
    }

    @Test func everyChangeableDefaultPassesTheRulesItEnforces() {
        // A command's own default must be recordable again (the rules never refuse the defaults themselves).
        for c in ShortcutCatalogue.all where c.isChangeable {
            #expect(ShortcutRules.refusal(c.defaultChord!, for: c.id, in: .defaults) == nil, "\(c.id)")
        }
    }

    @Test func theFixedOnesAreTheStandardAndBareKeys() {
        let fixed = Set(ShortcutCatalogue.all.filter { !$0.isChangeable }.map(\.id))
        #expect(fixed == [.appSettings, .appQuit, .journalCopyClean, .journalUndo, .viewerToggleMode, .viewerCompare,
                          .viewerClose, .viewerCopy, .panelUndo, .panelClose])
        for c in ShortcutCatalogue.all where !c.isChangeable { #expect(c.fixedReason?.isEmpty == false) }
    }

    @Test func scopesOverlapOnlyThroughTheApp() {
        #expect(ShortcutScope.app.overlaps(.journal) && ShortcutScope.viewer.overlaps(.app))
        #expect(ShortcutScope.journal.overlaps(.journal))
        #expect(!ShortcutScope.journal.overlaps(.viewer))
        #expect(!ShortcutScope.viewer.overlaps(.menuBarPanel))
        #expect(!ShortcutScope.menuBarPanel.overlaps(.journal))
    }

    @Test func theDefaultsAreTheChordsTheAppHadBefore() {
        let d = KeyBindings.defaults
        #expect(d.display(for: .appOpenJournal) == "⌘J")
        #expect(d.display(for: .appSettings) == "⌘,")
        #expect(d.display(for: .appQuit) == "⌘Q")
        #expect(d.display(for: .journalImport) == "⌘O")
        #expect(d.display(for: .journalCopyClean) == "⌘C")
        #expect(d.display(for: .journalCopyOriginal) == "⌥⌘C")
        #expect(d.display(for: .journalCopyAsShown) == "⇧⌘C")
        #expect(d.display(for: .journalDelete) == "⌘⌫")
        #expect(d.display(for: .journalShowDetails) == "⌥⌘I")
        #expect(d.display(for: .journalUndo) == "⌘Z")
        #expect(d.display(for: .viewerToggleMode) == "⇥")
        #expect(d.display(for: .viewerCompare) == "Space")
        #expect(d.display(for: .viewerClose) == "Esc")
        #expect(d.display(for: .viewerCopy) == "⌘C")
        #expect(d.display(for: .viewerCopyOriginal) == "⌥⌘C")
        #expect(d.display(for: .viewerZoomIn) == "⌘=")
        #expect(d.display(for: .viewerZoomOut) == "⌘−")
        #expect(d.display(for: .viewerActualSize) == "⌘0")
        #expect(d.display(for: .viewerZoomToFit) == "⌘9")
        #expect(d.display(for: .viewerFindings) == "⌥⌘I")
        #expect(d.display(for: .panelUndo) == "⌘Z")
        #expect(d.display(for: .panelClose) == "Esc")
        #expect(d.chords(for: .viewerZoomIn).contains(KeyChord("=", [.shift, .command])))
    }
}

@Suite struct KeyBindingsResolverTests {
    @Test func defaultOverrideAndCleared() {
        var b = KeyBindings.defaults
        #expect(b.chord(for: .journalImport) == KeyChord("o", .command))
        #expect(!b.isChanged(.journalImport))

        b.set(KeyChord("k", [.control, .command]), for: .journalImport)
        #expect(b.chord(for: .journalImport) == KeyChord("k", [.control, .command]))
        #expect(b.isChanged(.journalImport) && b.changedCount == 1)
        #expect(b.overrides == ["journal.import": "ctrl+cmd+k"])

        b.set(nil, for: .journalImport)
        #expect(b.chord(for: .journalImport) == nil)
        #expect(b.chords(for: .journalImport).isEmpty)
        #expect(b.display(for: .journalImport) == nil)
        #expect(b.overrides == ["journal.import": "none"])

        b.reset(.journalImport)
        #expect(b.chord(for: .journalImport) == KeyChord("o", .command))
        #expect(b.overrides.isEmpty)
    }

    @Test func settingTheDefaultRemovesTheOverride() {
        var b = KeyBindings.defaults
        b.set(KeyChord("k", .command), for: .viewerZoomOut)
        b.set(KeyChord("-", .command), for: .viewerZoomOut)
        #expect(b.overrides.isEmpty)
    }

    @Test func fixedCommandsIgnoreChangesAndStoredOverrides() {
        var b = KeyBindings.defaults
        b.set(KeyChord("k", .command), for: .appQuit)
        #expect(b.overrides.isEmpty)
        let stored = KeyBindings(overrides: ["app.quit": "cmd+k", "viewer.copy": "none"])
        #expect(stored.chord(for: .appQuit) == KeyChord("q", .command))
        #expect(stored.chord(for: .viewerCopy) == KeyChord("c", .command))
        #expect(stored.changedCount == 0)
    }

    @Test func aChangedBindingDropsTheDefaultAliases() {
        var b = KeyBindings.defaults
        b.set(KeyChord("k", [.control, .command]), for: .viewerZoomIn)
        #expect(b.chords(for: .viewerZoomIn) == [KeyChord("k", [.control, .command])])
        #expect(b.command(matching: KeyChord("=", [.shift, .command]), among: [.viewerZoomIn]) == nil)
    }

    @Test func resetAllAlsoDropsIdsFromOtherVersions() {
        var b = KeyBindings(overrides: ["journal.import": "cmd+k", "journal.someFutureCommand": "cmd+y"])
        #expect(b.changedCount == 1)
        b.resetAll()
        #expect(b.overrides.isEmpty)
    }

    @Test func commandMatchingPicksOnlyAmongTheGivenIds() {
        let b = KeyBindings.defaults
        let c = KeyChord("c", [.option, .command])
        #expect(b.command(matching: c, among: [.viewerCopy, .viewerCopyOriginal]) == .viewerCopyOriginal)
        #expect(b.command(matching: c, among: [.viewerCopy]) == nil)
    }
}

@Suite struct ShortcutRulesTests {
    @Test func aChordInTheSameScopeIsRefusedNamingTheOtherCommand() {
        let b = KeyBindings.defaults
        let refusal = ShortcutRules.refusal(KeyChord("c", [.shift, .command]), for: .journalImport, in: b)
        #expect(refusal == .conflict(.journalCopyAsShown))
        #expect(refusal?.message(for: KeyChord("c", [.shift, .command])) == "⇧⌘C is already Copy As Shown in the Journal.")
    }

    @Test func anAppCommandConflictsWithEveryWindow() {
        let b = KeyBindings.defaults
        // ⌘J is Open Journal (App): refused for a Viewer command too.
        #expect(ShortcutRules.refusal(KeyChord("j", .command), for: .viewerZoomOut, in: b) == .conflict(.appOpenJournal))
        // And an App command cannot take a Journal command's chord.
        #expect(ShortcutRules.refusal(KeyChord("o", .command), for: .appOpenJournal, in: b) == .conflict(.journalImport))
    }

    @Test func separateWindowsMayShareAChord() {
        let b = KeyBindings.defaults
        // ⌥⌘I is Show Details in the Journal and Show Findings in the Viewer: separate windows, no conflict.
        #expect(ShortcutRules.refusal(KeyChord("o", .command), for: .viewerZoomToFit, in: b) == nil)
        #expect(ShortcutRules.refusal(KeyChord("i", [.option, .command]), for: .journalCopyOriginal, in: b) == .conflict(.journalShowDetails))
    }

    @Test func theDefaultAliasConflictsToo() {
        let b = KeyBindings.defaults
        #expect(ShortcutRules.refusal(KeyChord("=", [.shift, .command]), for: .viewerZoomOut, in: b) == .conflict(.viewerZoomIn))
    }

    @Test func aClearedCommandFreesItsChord() {
        var b = KeyBindings.defaults
        b.set(nil, for: .journalCopyAsShown)
        #expect(ShortcutRules.refusal(KeyChord("c", [.shift, .command]), for: .journalImport, in: b) == nil)
    }

    @Test func reservedChordsAreRefused() {
        let b = KeyBindings.defaults
        let reserved: [KeyChord] = [
            KeyChord("q", .command), KeyChord("h", .command), KeyChord(.special(.tab), .command),
            KeyChord(.special(.space), .command), KeyChord(.special(.escape), [.option, .command]),
            KeyChord("3", [.shift, .command]), KeyChord("4", [.shift, .command]), KeyChord("5", [.shift, .command]),
            KeyChord("4", [.control, .shift, .command]), KeyChord("w", .command), KeyChord("v", .command),
        ]
        for chord in reserved {
            guard case .reserved = ShortcutRules.refusal(chord, for: .journalImport, in: b) else {
                Issue.record("\(chord.display) was not refused as reserved")
                continue
            }
        }
        #expect(ShortcutRules.refusal(KeyChord("5", [.shift, .command]), for: .journalImport, in: b)?
            .message(for: KeyChord("5", [.shift, .command])) == "⇧⌘5 is used by macOS for screenshots.")
    }

    @Test func aChordNeedsCommandOrControlOrAFunctionKey() {
        let b = KeyBindings.defaults
        #expect(ShortcutRules.refusal(KeyChord("k"), for: .journalImport, in: b) == .needsCommandOrControl)
        #expect(ShortcutRules.refusal(KeyChord("k", .shift), for: .journalImport, in: b) == .needsCommandOrControl)
        #expect(ShortcutRules.refusal(KeyChord("k", [.option, .shift]), for: .journalImport, in: b) == .needsCommandOrControl)
        #expect(ShortcutRules.refusal(KeyChord(.special(.return)), for: .journalImport, in: b) == .needsCommandOrControl)
        #expect(ShortcutRules.refusal(KeyChord("k", .control), for: .journalImport, in: b) == nil)
        #expect(ShortcutRules.refusal(KeyChord(.special(.f5)), for: .journalImport, in: b) == nil)
        #expect(ShortcutRules.refusal(KeyChord(.special(.f5), .shift), for: .journalImport, in: b) == nil)
    }

    @Test func aFixedCommandRefusesEveryChord() {
        #expect(ShortcutRules.refusal(KeyChord("k", .command), for: .appQuit, in: .defaults) == .fixed)
    }

    @Test func aHandEditedClashIsReported() {
        let b = KeyBindings(overrides: ["journal.import": "shift+cmd+c"])
        let pairs = ShortcutRules.conflicts(in: b)
        #expect(pairs.count == 1)
        #expect(pairs.first.map { [$0.0, $0.1] } == [.journalImport, .journalCopyAsShown])
    }
}

@Suite struct KeyChordFormTests {
    @Test func storageRoundTripsEveryShape() {
        let chords: [KeyChord] = [
            KeyChord("c", [.control, .option, .shift, .command]), KeyChord(",", .command), KeyChord("-", .command),
            KeyChord("+", .command), KeyChord("f", .command), KeyChord(.special(.delete), .command),
            KeyChord(.special(.f12)), KeyChord(.special(.space), .control), KeyChord(":", [.shift, .command]),
        ]
        for c in chords {
            #expect(KeyChord(storage: c.storage) == c, "\(c.storage)")
        }
        #expect(KeyChord("c", [.command, .option, .shift, .control]).storage == "ctrl+opt+shift+cmd+c")
        // A letter that spells a special key's name, and "+", are stored unambiguously.
        #expect(KeyChord("f", .command).storage == "cmd+f")
        #expect(KeyChord("+", .command).storage == "cmd+char:+")
    }

    @Test func malformedStorageIsNil() {
        for text in ["", "cmd+", "cmd+cmd+c", "cmd+ab", "hyper+c", "cmd+char:", "cmd+char:ab", "+"] {
            #expect(KeyChord(storage: text) == nil, "\(text)")
        }
    }

    @Test func letterCaseIsNormalised() {
        #expect(KeyChord(storage: "cmd+C") == KeyChord("c", .command))
        #expect(KeyChord("C", .command) == KeyChord("c", .command))
    }

    @Test func displayAndSpokenNames() {
        #expect(KeyChord("c", [.command, .shift, .option, .control]).display == "⌃⌥⇧⌘C")
        #expect(KeyChord("c", [.option, .command]).spokenName == "Option Command C")
        #expect(KeyChord(.special(.delete), .command).spokenName == "Command Delete")
        #expect(KeyChord(",", .command).spokenName == "Command Comma")
        #expect(KeyChord(.special(.f5)).display == "F5")
    }
}

@Suite struct KeyPressParsingTests {
    @Test func charactersComeFromTheUnmodifiedKey() {
        #expect(KeyChord.from(keyCode: 8, baseCharacters: "c", modifiers: .command) == KeyChord("c", .command))
        #expect(KeyChord.from(keyCode: 8, baseCharacters: "C", modifiers: [.shift, .command]) == KeyChord("c", [.shift, .command]))
        #expect(KeyChord.from(keyCode: 34, baseCharacters: "i", modifiers: [.option, .command]) == KeyChord("i", [.option, .command]))
        #expect(KeyChord.from(keyCode: 24, baseCharacters: "=", modifiers: [.shift, .command]) == KeyChord("=", [.shift, .command]))
        // AZERTY: the key that types "a" is ⌘A whatever its position.
        #expect(KeyChord.from(keyCode: 12, baseCharacters: "a", modifiers: .command) == KeyChord("a", .command))
    }

    @Test func specialKeysComeFromTheKeyCode() {
        #expect(KeyChord.from(keyCode: 53, baseCharacters: "\u{1b}", modifiers: []) == KeyChord(.special(.escape)))
        #expect(KeyChord.from(keyCode: 51, baseCharacters: "\u{7f}", modifiers: .command) == KeyChord(.special(.delete), .command))
        #expect(KeyChord.from(keyCode: 117, baseCharacters: nil, modifiers: []) == KeyChord(.special(.forwardDelete)))
        #expect(KeyChord.from(keyCode: 48, baseCharacters: "\t", modifiers: []) == KeyChord(.special(.tab)))
        #expect(KeyChord.from(keyCode: 49, baseCharacters: " ", modifiers: .control) == KeyChord(.special(.space), .control))
        #expect(KeyChord.from(keyCode: 36, baseCharacters: "\r", modifiers: .command) == KeyChord(.special(.return), .command))
        #expect(KeyChord.from(keyCode: 96, baseCharacters: "\u{F708}", modifiers: []) == KeyChord(.special(.f5)))
        #expect(KeyChord.from(keyCode: 126, baseCharacters: "\u{F700}", modifiers: .command) == KeyChord(.special(.upArrow), .command))
    }

    @Test func aModifierAloneOrAControlCharacterIsNoChord() {
        // Pressing ⌘ alone reaches a key-down handler only as flagsChanged; a stray control character is not a key.
        #expect(KeyChord.from(keyCode: 55, baseCharacters: "", modifiers: .command) == nil)
        #expect(KeyChord.from(keyCode: 0, baseCharacters: nil, modifiers: .command) == nil)
        #expect(KeyChord.from(keyCode: 0, baseCharacters: "\u{01}", modifiers: .control) == nil)
        #expect(KeyChord.from(keyCode: 0, baseCharacters: "ab", modifiers: .command) == nil)
    }
}

@Suite struct KeyBindingsStorageTests {
    @Test func aDocumentWithoutShortcutsDecodesToTheDefaults() throws {
        // Every settings document written before G-20.
        let json = Data(#"{"appearance": "dark", "journalRetentionHours": 168}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: json)
        #expect(s.keyBindings == .defaults)
        #expect(s.appearance == .dark)
    }

    @Test func aDocumentRoundTripsItsShortcuts() throws {
        var s = Settings.default
        s.keyBindings.set(KeyChord("k", [.control, .command]), for: .journalImport)
        s.keyBindings.set(nil, for: .viewerZoomToFit)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Settings.self, from: data)
        #expect(back.keyBindings == s.keyBindings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""shortcuts.overrides""#))
    }

    @Test func aMalformedShortcutsValueReadsAsDefaultsAndKeepsTheRest() throws {
        let json = Data(#"{"shortcuts.overrides": 7, "appearance": "light"}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: json)
        #expect(s.keyBindings == .defaults)
        #expect(s.appearance == .light)
    }

    @Test func unknownIdsAndUnreadableChordsAreKeptButIgnored() throws {
        let json = Data(#"{"shortcuts.overrides": {"journal.import": "cmd+??", "viewer.zoomOut": "ctrl+cmd+k", "future.thing": "cmd+y"}}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: json)
        #expect(s.keyBindings.chord(for: .journalImport) == KeyChord("o", .command))
        #expect(s.keyBindings.chord(for: .viewerZoomOut) == KeyChord("k", [.control, .command]))
        #expect(s.keyBindings.changedCount == 1)
        // Written back unchanged, so another version's entry survives this one.
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(again.keyBindings.overrides["future.thing"] == "cmd+y")
    }

    @Test func theDefaultsStorePersistsAndCoercesBindings() {
        let temp = TestDefaults()
        let store = UserDefaultsSettingsStore(defaults: temp.defaults)
        #expect(store.current().keyBindings == .defaults)
        store.update { $0.keyBindings.set(KeyChord("k", [.control, .command]), for: .journalImport) }
        #expect(temp.defaults.dictionary(forKey: "shortcuts.overrides") as? [String: String] == ["journal.import": "ctrl+cmd+k"])
        let reopened = UserDefaultsSettingsStore(defaults: temp.defaults)
        #expect(reopened.current().keyBindings.chord(for: .journalImport) == KeyChord("k", [.control, .command]))

        // A value of the wrong type reads as no changes.
        temp.defaults.set("cmd+k", forKey: "shortcuts.overrides")
        #expect(UserDefaultsSettingsStore(defaults: temp.defaults).current().keyBindings == .defaults)
    }
}
