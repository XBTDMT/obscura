import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ObscuraSettingsUI
import ObscuraDetect
import ObscuraJournal
import ObscuraPrefs
import ObscuraUIKit
import ObscuraTestSupport

// Every key below is made up (EXAMPLE bodies); none is a real credential.

@MainActor
private func loadedSession() async throws -> (SettingsSession, SQLiteJournalStore) {
    let journal = try SampleData.makeJournal()
    let session = SettingsSession(journal: journal)
    await session.load()
    return (session, journal)
}

/// F17 (G-36): a folder named in the settings but not confirmed in Obscura counts as one that needs the person, so the
/// Protection pane and its sidebar mark say so.
@Suite struct UnconfirmedFolderFactsTests {
    @Test func unconfirmedFoldersNeedThePerson() {
        var s = ObscuraPrefs.Settings.default
        s.guardsDownloads = true
        s.extraFolders = ["/home/example/Shots", "/home/example/Mine"]
        let system = SystemSnapshot(screenshotFolder: URL(filePath: "/home/example/Desktop"), screenshotAccess: .granted,
                                    downloads: URL(filePath: "/home/example/Downloads"), downloadsAccess: .granted, folderAccess: [:],
                                    floatingThumbnail: false, notificationsDenied: nil, loginItem: .disabled)
        #expect(ProtectionFacts.foldersNeedingYou(s, system) == 0, "positive control: all granted, nothing unconfirmed")
        #expect(ProtectionFacts.foldersNeedingYou(s, system, unconfirmed: ["/home/example/Shots", "/home/example/Downloads"]) == 2)
    }
}

@Suite @MainActor struct DetectorPersistenceTests {
    @Test func defaultsCountSeventyOneOfEightyFour() async throws {
        let (session, _) = try await loadedSession()
        #expect(session.totalCount == 84)
        #expect(session.onCount == 71)
        #expect(CountCopy.on(session.onCount, of: session.totalCount) == "71 of 84 on")
        #expect(session.onCount(in: .network) == 0)
    }

    @Test func detectorTogglePersists() async throws {
        let (session, journal) = try await loadedSession()
        var recompiles = 0
        session.onCatalogueChange = { recompiles += 1 }
        let anthropic = try #require(SettingsSession.builtInByID["ai.anthropic.apikey"])

        await session.setEnabled(anthropic.id, false)

        #expect(try await journal.detectorState()[anthropic.id] == false)
        #expect(recompiles == 1)
        let reopened = SettingsSession(journal: journal)
        await reopened.load()
        #expect(reopened.isOn(anthropic) == false)
        #expect(reopened.onCount == 70)
    }

    @Test func categorySwitchTurnsEveryDetectorOn() async throws {
        let (session, journal) = try await loadedSession()
        await session.setCategory(.network, true)
        #expect(session.onCount(in: .network) == 5)
        let state = try await journal.detectorState()
        #expect(session.detectors(in: .network).allSatisfy { state[$0.id] == true })
    }

    @Test func overrideRoundTrips() async throws {
        let (session, journal) = try await loadedSession()
        let anthropic = try #require(SettingsSession.builtInByID["ai.anthropic.apikey"])
        let specs: [PatternSpec] = [.prefix("sk-ant-", n: 24), .regex(#"\bANTH-[0-9]{6}\b"#)]

        try await session.savePatterns(specs, for: anthropic)

        let stored = try #require(try await journal.overrides().first { $0.detectorID == anthropic.id })
        #expect(try JSONDecoder().decode([PatternSpec].self, from: Data(stored.specsJSON.utf8)) == specs)
        let reopened = SettingsSession(journal: journal)
        await reopened.load()
        #expect(reopened.patterns(for: anthropic) == specs)
        #expect(reopened.isEdited(anthropic.id))
        #expect(reopened.editedCount == 1)

        await reopened.reset(anthropic)
        #expect(try await journal.overrides().isEmpty)
        #expect(reopened.patterns(for: anthropic) == anthropic.patterns)
    }

    @Test func savingTheBuiltInListClearsTheOverride() async throws {
        let (session, journal) = try await loadedSession()
        let anthropic = try #require(SettingsSession.builtInByID["ai.anthropic.apikey"])
        try await session.savePatterns([.regex("ANTH")], for: anthropic)
        try await session.savePatterns(anthropic.patterns, for: anthropic)
        #expect(try await journal.overrides().isEmpty)
        #expect(!session.isEdited(anthropic.id))
    }

    @Test func anInvalidRegexIsNeverStored() async throws {
        let (session, journal) = try await loadedSession()
        let anthropic = try #require(SettingsSession.builtInByID["ai.anthropic.apikey"])
        await #expect(throws: PatternError.self) {
            try await session.savePatterns([.regex("sk-ant-[A-Z{{")], for: anthropic)
        }
        #expect(try await journal.overrides().isEmpty)
        #expect(PatternCopy.message(for: .invalidRegex("sk-ant-[A-Z{{")) == "This isn’t a valid regular expression — “[” is never closed")
    }

    @Test func anEmptyPatternListIsStoredAndNeverMatches() async throws {
        let (session, _) = try await loadedSession()
        let serial = try #require(SettingsSession.builtInByID["network.apple.serial"])
        try await session.savePatterns([], for: serial)
        #expect(session.patterns(for: serial).isEmpty)
        #expect(session.isEdited(serial.id))
    }
}

@Suite @MainActor struct CustomRuleTests {
    @Test func previewReadsAsASentence() {
        #expect(RulePreview.sentence(action: .blackOut, kind: .example, value: "CUS-004213") == "Things like “CUS-004213” will be blacked out")
        #expect(RulePreview.sentence(action: .allow, kind: .exactText, value: "Project Falcon") == "The text “Project Falcon” will never be blacked out")
        #expect(PatternSpec(kind: .example, value: "CUS-004213").humanDescription == "“CUS”, “-”, 6 digits")
    }

    @Test func validationsUseThePaneWords() {
        var prefix = RuleDraft(action: .blackOut)
        prefix.kind = .prefix
        prefix.value = "c"
        guard case .failure(let short) = prefix.result else { Issue.record("a one-letter prefix compiled"); return }
        #expect(PatternCopy.message(for: short) == "Use at least 2 characters")

        var example = RuleDraft(action: .blackOut)
        example.value = "AB"
        guard case .failure(let tooShort) = example.result else { Issue.record("a two-letter example compiled"); return }
        #expect(PatternCopy.message(for: tooShort) == "Paste a longer example")
    }

    @Test func aRuleIsStoredAsARuleRecord() async throws {
        let (session, journal) = try await loadedSession()
        var draft = RuleDraft(action: .blackOut)
        draft.value = "CUS-004213"
        draft.name = "Customer ids"
        await session.saveRule(draft.record(sortOrder: 0))

        let rules = try await journal.rules().compactMap(\.readable)
        #expect(rules.count == 1)
        #expect(rules.first?.kind == .example && rules.first?.value == "CUS-004213" && rules.first?.name == "Customer ids")
        #expect(CountCopy.rulesSidebar(blackOut: session.blackOutRules.count, never: session.allowRules.count) == "1 rule")

        await session.setRuleEnabled(try #require(rules.first?.id), false)
        #expect(try await journal.rules().first?.readable?.enabled == false)
        await session.deleteRule(try #require(rules.first?.id))
        #expect(try await journal.rules().isEmpty)
    }

    @Test func exportThenImportRestoresRules() async throws {
        let (session, _) = try await loadedSession()
        await session.saveRule(RuleRecord(action: .allow, kind: .exactText, value: "Project Falcon", createdAt: Date(), sortOrder: 0))
        let data = try await session.exportRules()

        let (other, otherJournal) = try await loadedSession()
        let report = try await other.importRules(data)
        #expect(report.rulesAdded.count == 1)
        #expect(try await otherJournal.rules().first?.readable?.value == "Project Falcon")
        #expect(other.allowRules.count == 1)
    }
}

@Suite @MainActor struct TestFooterTests {
    @Test func findsAMadeUpKey() async throws {
        let (session, _) = try await loadedSession()
        let catalogue = try #require(session.compiledCatalogue())
        let line = "ANTHROPIC_API_KEY=sk-ant-api03-EXAMPLE000000000000000000"

        let result = LineTester.evaluate(line, catalogue: catalogue)

        guard case .blackedOut(let hits) = result.outcome else { Issue.record("nothing was blacked out"); return }
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Anthropic API key")
        #expect(hits.first?.patternNumber == 1)
        #expect(result.reason == "because it is an Anthropic API key")
        #expect(result.tail == "1 secret, pattern 1 of 1")
        let secret = try #require(hits.first.flatMap { Range($0.secretRange, in: line) })
        #expect(line[secret].hasPrefix("sk-ant-"))
    }

    /// G-19 #6: the "pattern N of M" tag can be switched off in plain words; regular expressions always show it.
    @Test func thePatternTagFollowsTheSetting() async throws {
        let (session, _) = try await loadedSession()
        let catalogue = try #require(session.compiledCatalogue())
        let result = LineTester.evaluate("ANTHROPIC_API_KEY=sk-ant-api03-EXAMPLE000000000000000000", catalogue: catalogue)
        #expect(result.tail(showingPatternNumber: true) == "1 secret, pattern 1 of 1")
        #expect(result.tail(showingPatternNumber: false) == "1 secret")
        var settings = ObscuraPrefs.Settings.default
        #expect(PatternDisplayOptions.showsPatternNumber(settings, regexMode: false), "on by default")
        settings.showsPatternNumber = false
        #expect(!PatternDisplayOptions.showsPatternNumber(settings, regexMode: false))
        #expect(PatternDisplayOptions.showsPatternNumber(settings, regexMode: true), "regex mode always names the pattern")
    }

    @Test func aNeverBlackOutRuleExplainsItself() async throws {
        let (session, _) = try await loadedSession()
        await session.saveRule(RuleRecord(action: .allow, kind: .exactText, value: "Project Falcon", createdAt: Date(), sortOrder: 0))
        let catalogue = try #require(session.compiledCatalogue())
        let result = LineTester.evaluate("TEAM_NAME=Project Falcon", catalogue: catalogue)
        #expect(result.outcome == .allowed(text: "Project Falcon"))
        #expect(result.reason == "because “Project Falcon” is on your Never black out list")
    }

    @Test func aTurnedOffDetectorNoLongerFires() async throws {
        let (session, _) = try await loadedSession()
        let before = session.compiledCatalogue()
        await session.setEnabled("ai.anthropic.apikey", false)
        let after = try #require(session.compiledCatalogue())
        #expect(before?.detectors.count != after.detectors.count)
        let result = LineTester.evaluate("ANTHROPIC_API_KEY=sk-ant-api03-EXAMPLE000000000000000000", catalogue: after)
        if case .blackedOut(let hits) = result.outcome { #expect(!hits.contains { $0.detectorID == "ai.anthropic.apikey" }) }
    }

    @Test func articlesFollowTheSound() {
        #expect(LineTester.becauseItIs("GitHub token") == "because it is a GitHub token")
        #expect(LineTester.becauseItIs("SSH private key") == "because it is an SSH private key")
        #expect(LineTester.becauseItIs("US Social Security number") == "because it is a US Social Security number")
    }
}

// MARK: - Rendering

@Suite(.serialized) @MainActor struct SettingsWindowRenderTests {
    static let snapshot = SystemSnapshot(
        screenshotFolder: URL(filePath: "/home/example/Desktop/Screenshots"), screenshotAccess: .granted,
        downloads: URL(filePath: "/home/example/Downloads"), downloadsAccess: .denied,
        folderAccess: ["/home/example/Projects/acme/exports": .granted, "/home/example/Documents/Invoices": .missing],
        floatingThumbnail: true, notificationsDenied: true, loginItem: .requiresApproval)

    @Test(arguments: SettingsPane.allCases)
    func everyPaneRenders(_ pane: SettingsPane) async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.extraFolders = Array(Self.snapshot.folderAccess.keys).sorted()
        let model = try await SampleData.model(entries: 3, settings: settings)
        for dark in [false, true] {
            let bitmap = try await render(model: model, pane: pane, dark: dark)
            #expect(bitmap.pixelsWide == 880 * 2 || bitmap.pixelsWide == 880)
            #expect(bitmap.pixelsHigh * 880 == bitmap.pixelsWide * 620)
            #expect(Self.distinctColours(bitmap) > 8, "the \(pane) pane drew almost nothing")
            if let dir = ProcessInfo.processInfo.environment["OBSCURA_SETTINGS_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let url = URL(filePath: dir).appending(path: "\(pane.rawValue)-\(dark ? "dark" : "light").png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    @Test func pausedProtectionLeadsWithResume() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.protectionPaused = true
        settings.guardsDownloads = true
        settings.fileHandling = .keepBoth
        let model = try await SampleData.model(entries: 0, settings: settings)
        for dark in [false, true] {
            let bitmap = try await render(model: model, pane: .protection, dark: dark)
            #expect(Self.distinctColours(bitmap) > 8)
            if let dir = ProcessInfo.processInfo.environment["OBSCURA_SETTINGS_SNAPSHOT_DIR"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "protection-paused-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// The rules panes in the states rules.html draws: a picked tile with an edited detector open, every category
    /// with opt-in detectors and an empty override, the rule editor open over five rules; plain words and regex.
    @Test(arguments: [false, true])
    func rulesPaneStatesRender(_ regex: Bool) async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.detectorsShowPatterns = regex
        let model = try await SampleData.model(entries: 1, settings: settings)
        let journal = model.journal
        let specs: [PatternSpec] = [.prefix("sk-ant-", n: 24), .regex(#"\bANTH-[0-9]{6}\b"#)]
        try await journal.setOverride("ai.anthropic.apikey", specsJSON: String(decoding: try JSONEncoder().encode(specs), as: UTF8.self))
        try await journal.setOverride("network.apple.serial", specsJSON: "[]")
        let now = Date()
        for (i, rule) in [(RuleAction.blackOut, RuleKind.example, "CUS-004213", true), (.blackOut, .label, "Employee ID", true),
                          (.blackOut, .prefix, "tok_", false), (.allow, .exactText, "Project Falcon", true),
                          (.allow, .example, "+1 555 010 0199", true)].enumerated() {
            try await journal.upsertRule(RuleRecord(action: rule.0, kind: rule.1, value: rule.2, enabled: rule.3, createdAt: now, sortOrder: i))
        }
        var draft = RuleDraft(action: .blackOut)
        draft.value = "CUS-004213"
        draft.name = "Customer ids"
        let states: [(String, SettingsPane, SettingsInitialState)] = [
            ("detectors-ai", .detectors, SettingsInitialState(tile: .ai, expanded: ["ai.anthropic.apikey"],
                                                              testLine: "ANTHROPIC_API_KEY=sk-ant-api03-EXAMPLE000000000000000000")),
            ("detectors-all", .detectors, SettingsInitialState(expanded: ["network.apple.serial"], openCategories: [.personal, .network])),
            ("detectors-network", .detectors, SettingsInitialState(tile: .network, expanded: ["network.apple.serial"])),
            ("rules-editor", .customRules, SettingsInitialState(ruleDraft: draft, testLine: "TEAM_NAME=Project Falcon")),
        ]
        for (name, pane, initial) in states {
            for dark in [false, true] {
                let bitmap = try await render(model: model, pane: pane, dark: dark, initial: initial)
                #expect(Self.distinctColours(bitmap) > 8, "\(name) drew almost nothing")
                if let dir = ProcessInfo.processInfo.environment["OBSCURA_SETTINGS_SNAPSHOT_DIR"] {
                    let url = URL(filePath: dir).appending(path: "\(name)-\(regex ? "regex" : "plain")-\(dark ? "dark" : "light").png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }

    /// G-19: every pane draws with its new options moved off their defaults (per-pane patterns, the tag off, catch
    /// sound, the badge room, orange Paused, click-only pause choices, confirm before Undo, the wipe, the slide, reopen
    /// to the Journal), light and dark.
    @Test func everyPaneRendersWithTheG19OptionsChanged() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.patternModeScope = .perPane
        settings.rulesShowPatterns = true
        settings.showsPatternNumber = false
        settings.catchSound = true
        settings.showsNotifications = false
        settings.reservesBadgeSpace = true
        settings.pausedColor = .orange
        settings.pausedUntil = .distantFuture
        settings.pauseChoicesOpen = .click
        settings.confirmsUndo = true
        settings.compareStyle = .wipe
        settings.journalInspectorMotion = .slide
        settings.reopenShows = .journal
        let model = try await SampleData.model(entries: 1, settings: settings)
        for pane in [SettingsPane.protection, .detectors, .customRules, .journalPrivacy, .about] {
            for dark in [false, true] {
                let bitmap = try await render(model: model, pane: pane, dark: dark)
                #expect(Self.distinctColours(bitmap) > 8, "\(pane.rawValue) drew almost nothing")
                if let dir = ProcessInfo.processInfo.environment["OBSCURA_SETTINGS_SNAPSHOT_DIR"] {
                    try bitmap.representation(using: .png, properties: [:])?
                        .write(to: URL(filePath: dir).appending(path: "g19-\(pane.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    /// G-23 / G-24: Journal & Privacy says where originals live and that they stay out of backups and search, and
    /// carries both search switches; it draws with each switch flipped from its default, light and dark.
    @Test func journalPrivacyShowsTheSearchSwitchesAndWhereOriginalsLive() async throws {
        #expect(JournalPrivacyCopy.originalsHelp("~/x").contains("kept out of Time Machine backups and Spotlight search"))
        #expect(JournalPrivacyCopy.spotlightHelp.contains("Never the secret itself"))
        #expect(JournalPrivacyCopy.tagsHelp.contains("Tags travel with the file when you share it"))
        var settings = ObscuraPrefs.Settings.default
        settings.indexesCatchesInSpotlight = !SearchIndexDefaults.spotlightEntries
        settings.tagsCoveredFiles = !SearchIndexDefaults.finderTags
        let model = try await SampleData.model(entries: 1, settings: settings)
        for dark in [false, true] {
            let bitmap = try await render(model: model, pane: .journalPrivacy, dark: dark)
            #expect(Self.distinctColours(bitmap) > 8, "Journal & Privacy drew almost nothing")
        }
    }

    private func render(model: AppModel, pane: SettingsPane, dark: Bool,
                        initial: SettingsInitialState = SettingsInitialState()) async throws -> NSBitmapImageRep {
        let view = SettingsWindow(model: model, pane: .constant(pane), services: .fixed(Self.snapshot), snapshot: Self.snapshot)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.settingsInitialState, initial)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 880, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))   // the session loads and the style sample renders
        host.layoutSubtreeIfNeeded()
        // Layer shadows on the side the screen draws them (ViewSnapshot), AppKit controls included.
        return try #require(ViewSnapshot.bitmap(host))
    }

    private static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let stepX = max(1, rep.pixelsWide / 60), stepY = max(1, rep.pixelsHigh / 40)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return seen.count
    }
}
