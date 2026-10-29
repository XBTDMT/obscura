// G-30: Custom Rules shows a rule whose value can't be read on this Mac apart from the working ones, says why and what
// to do, lets it be re-entered under its id or deleted, and the export panel says the file is not encrypted. Every key
// store here lives in memory; no test touches the real Keychain. Every value is made up.
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ObscuraSettingsUI
import ObscuraJournal
import ObscuraPrefs
import ObscuraUIKit
import ObscuraTestSupport

@MainActor
@Suite struct UnreadableRulesPaneTests {
    static let created = Date(timeIntervalSince1970: 1_793_000_000)
    static let blackOut = RuleRecord(action: .blackOut, kind: .exactText, value: "EXAMPLE-kumquat-launch-code-7f3a9c", name: "Launch code",
                                     createdAt: created, sortOrder: 0)
    static let allow = RuleRecord(action: .allow, kind: .example, value: "EXAMPLE-Project-Falcon-a71e", createdAt: created, sortOrder: 1)
    static let readable = RuleRecord(action: .blackOut, kind: .prefix, value: "EXAMPLEtok_", tokenLength: 24, createdAt: created, sortOrder: 2)

    /// A Journal whose first two rules were sealed with a key this Mac no longer has, and a third saved since.
    static func journalWithUnreadableRules() async throws -> SQLiteJournalStore {
        let before = try SampleData.makeJournal()
        try await before.upsertRule(blackOut)
        try await before.upsertRule(allow)
        let after = try SQLiteJournalStore(root: before.root, ruleKeys: InMemoryRuleKeyStore())
        try await after.upsertRule(readable)
        return after
    }

    @Test func unreadableRulesAreListedApartWithWhatToDo() async throws {
        let journal = try await Self.journalWithUnreadableRules()
        let session = SettingsSession(journal: journal)
        await session.load()
        #expect(session.rules == [Self.readable])
        #expect(session.unreadableRules.map(\.id) == [Self.blackOut.id, Self.allow.id])
        #expect(session.unreadableRules.allSatisfy { $0.problem == .otherKey })

        let row = UnreadableRuleCopy.row(try #require(session.unreadableRules.first))
        #expect(row == "Black out “Launch code”: can’t be read on this Mac — re-enter it")
        #expect(!row.contains(Self.blackOut.value), "an unreadable row never shows a value")
        #expect(UnreadableRuleCopy.heading(2) == "2 rules can’t be read on this Mac")
        #expect(UnreadableRuleCopy.note(session.unreadableRules).contains("what they black out is not blacked out"))
        let waiting = UnreadableRule(id: "custom.x", action: .allow, kind: .exactText, createdAt: Self.created, sortOrder: 0, problem: .keyUnavailable)
        #expect(UnreadableRuleCopy.row(waiting).hasSuffix("waiting for the keychain"))

        // The catalogue preview compiles the readable rule only.
        let catalogue = try #require(session.compiledCatalogue())
        #expect(catalogue.detectors.filter { $0.detector.id.hasPrefix("custom.") }.count == 1)
    }

    @Test func reenteringReplacesTheUnreadableRuleUnderItsIdAndDeleteRemovesOne() async throws {
        let journal = try await Self.journalWithUnreadableRules()
        let session = SettingsSession(journal: journal)
        await session.load()
        var draft = RuleDraft(reentering: try #require(session.unreadableRules.first))
        #expect(draft.value.isEmpty && draft.reentering && draft.action == .blackOut && draft.name == "Launch code")
        draft.value = Self.blackOut.value
        await session.saveRule(draft.record(sortOrder: 99))
        #expect(session.unreadableRules.map(\.id) == [Self.allow.id])
        #expect(session.rules.map(\.id) == [Self.blackOut.id, Self.readable.id], "it keeps its place")
        #expect(try await journal.rules().first == .readable(Self.blackOut))

        await session.deleteRule(Self.allow.id)
        #expect(session.unreadableRules.isEmpty)
        #expect(try await journal.rules().allSatisfy { $0.readable != nil })
    }

    @Test func theExportPanelSaysTheFileIsNotEncryptedAndWhatIsLeftOut() {
        #expect(ExportCopy.panelMessage(unreadable: 0).contains("not encrypted"))
        #expect(ExportCopy.panelMessage(unreadable: 2).hasSuffix("2 rules that can’t be read on this Mac are left out."))
        var report = ImportReport(policy: .keepExisting)
        report.rulesRecovered = ["custom.a", "custom.b"]
        #expect(ImportCopy.summary(report) == "Imported: 0 new, 2 replaced, 0 already here.")
    }

    /// The pane draws the unreadable group (light and dark), plain words and regex mode.
    @Test(arguments: [false, true])
    func thePaneRendersUnreadableRules(_ regex: Bool) async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.detectorsShowPatterns = regex
        let journal = try await Self.journalWithUnreadableRules()
        let model = AppModel(engine: nil, journal: journal, settings: InMemorySettingsStore(settings), router: RecordingRouter(), ownsRouter: true)
        model.start()
        let snapshot = SystemSnapshot.placeholder
        for dark in [false, true] {
            let view = SettingsWindow(model: model, pane: .constant(.customRules), services: .fixed(snapshot), snapshot: snapshot)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 880, height: 620)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(600))   // the session loads
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(ViewSnapshot.bitmap(host))
            #expect(bitmap.pixelsWide >= 880)
            if let dir = ProcessInfo.processInfo.environment["OBSCURA_SETTINGS_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(filePath: dir).appending(path: "rules-unreadable-\(regex ? "regex" : "plain")-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
