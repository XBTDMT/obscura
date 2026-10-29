import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ObscuraSettingsUI
import ObscuraPrefs
import ObscuraUIKit

// G-20: the Keyboard Shortcuts pane: the recorder's rules, its words, the live path into the settings, and the pane
// drawn in its states.

@Suite struct ShortcutRecorderTests {
    @Test func escCancelsDeleteClearsEverythingElseIsAChord() {
        #expect(ShortcutRecording.interpret(nil) == .ignore)
        #expect(ShortcutRecording.interpret(KeyChord(.special(.escape))) == .cancel)
        #expect(ShortcutRecording.interpret(KeyChord(.special(.delete))) == .clear)
        #expect(ShortcutRecording.interpret(KeyChord(.special(.forwardDelete))) == .clear)
        // With a modifier, Delete and Esc are chords like any other (⌘⌫ is the Journal's Delete).
        #expect(ShortcutRecording.interpret(KeyChord(.special(.delete), .command)) == .record(KeyChord(.special(.delete), .command)))
        #expect(ShortcutRecording.interpret(KeyChord(.special(.escape), [.option, .command])) == .record(KeyChord(.special(.escape), [.option, .command])))
        #expect(ShortcutRecording.interpret(KeyChord("k", .command)) == .record(KeyChord("k", .command)))
        // A bare letter is handed on, and the rules refuse it (it needs ⌘ or ⌃).
        #expect(ShortcutRecording.interpret(KeyChord("k")) == .record(KeyChord("k")))
    }

    @Test func aKeyPressBecomesTheRecordedChord() {
        // The whole path the monitor takes: event values → chord → outcome.
        let chord = KeyChord.from(keyCode: 34, baseCharacters: "i", modifiers: .init([.option, .command, .capsLock]))
        #expect(ShortcutRecording.interpret(chord) == .record(KeyChord("i", [.option, .command])))
        let esc = KeyChord.from(keyCode: 53, baseCharacters: "\u{1b}", modifiers: .init([]))
        #expect(ShortcutRecording.interpret(esc) == .cancel)
        let modifierOnly = KeyChord.from(keyCode: 58, baseCharacters: "", modifiers: .init(.option))
        #expect(ShortcutRecording.interpret(modifierOnly) == .ignore)
    }
}

@Suite struct ShortcutsCopyTests {
    @Test func sidebarAndHeadline() {
        #expect(ShortcutsCopy.sidebarValue(changed: 0) == "Defaults")
        #expect(ShortcutsCopy.sidebarValue(changed: 2) == "2 changed")
        #expect(ShortcutsCopy.headline(changed: 0) == "Every shortcut is at its default")
        #expect(ShortcutsCopy.headline(changed: 1) == "1 shortcut changed")
        #expect(ShortcutsCopy.headline(changed: 3) == "3 shortcuts changed")
    }

    @Test func voiceOverWords() {
        let c = ShortcutID.journalCopyOriginal.command
        #expect(ShortcutsCopy.recorderLabel(c.title) == "Shortcut for Copy Original")
        #expect(ShortcutsCopy.spoken(c.defaultChord) == "Option Command C")
        #expect(ShortcutsCopy.spoken(nil) == "None")
        #expect(ShortcutsCopy.recorded(c, KeyChord("k", [.control, .command])) == "Copy Original is now Control Command K.")
        #expect(ShortcutsCopy.fixedValue(KeyChord("q", .command)) == "Command Q, can't be changed")
        #expect(ShortcutsCopy.resetLabel(c) == "Reset Copy Original to ⌥⌘C")
        #expect(ShortcutsCopy.defaultLine(c) == "Default: ⌥⌘C")
    }

    @Test func storedConflictNamesTheOtherCommand() {
        #expect(ShortcutsCopy.storedConflict(with: .journalCopyAsShown) == "Same keys as Copy As Shown in the Journal. Change one of them.")
    }
}

@Suite @MainActor struct ShortcutsPaneTests {
    @Test func aChangeReachesTheModelAtOnce() async throws {
        let model = try await SampleData.model(entries: 0, settings: .default)
        #expect(model.settings.keyBindings.chord(for: .journalImport) == KeyChord("o", .command))
        model.updateSettings { $0.keyBindings.set(KeyChord("k", [.control, .command]), for: .journalImport) }
        // Every surface reads `model.settings.keyBindings`; the model has the change before the next render.
        #expect(model.settings.keyBindings.chord(for: .journalImport) == KeyChord("k", [.control, .command]))
        #expect(model.settingsStore.current().keyBindings.chord(for: .journalImport) == KeyChord("k", [.control, .command]))
        model.updateSettings { $0.keyBindings.resetAll() }
        #expect(model.settings.keyBindings == .defaults)
    }

    @Test func thePaneIsListedAndSearchable() {
        #expect(SettingsPane.allCases.contains(.shortcuts))
        #expect(SidebarCopy.title(.shortcuts) == "Keyboard Shortcuts")
        #expect(SidebarCopy.keywords(.shortcuts).contains { $0.contains("key bindings") })
    }

    /// Defaults; and changed rows (a reset button each), a cleared one and a hand-edited clash. Light and dark.
    @Test(arguments: ["defaults", "changed"])
    func thePaneRenders(_ state: String) async throws {
        var settings = ObscuraPrefs.Settings.default
        if state == "changed" {
            settings.keyBindings.set(KeyChord("k", [.control, .command]), for: .journalImport)
            settings.keyBindings.set(nil, for: .viewerZoomToFit)
            settings.keyBindings = KeyBindings(overrides: settings.keyBindings.overrides.merging(["viewer.zoomOut": "cmd+0"]) { a, _ in a })
        }
        let model = try await SampleData.model(entries: 0, settings: settings)
        for dark in [false, true] {
            let view = SettingsWindow(model: model, pane: .constant(.shortcuts), services: .fixed(SettingsWindowRenderTests.snapshot),
                                      snapshot: SettingsWindowRenderTests.snapshot)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 880, height: 620)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            #expect(rep.pixelsHigh * 880 == rep.pixelsWide * 620)
            if let dir = ProcessInfo.processInfo.environment["OBSCURA_SETTINGS_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(filePath: dir).appending(path: "shortcuts-\(state)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
