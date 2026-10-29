// G-24 through the engine: a real catch of a made-up key labels the covered file for search with the kind of secret
// only; Undo takes the label off, Redo puts it back; clipboard catches get none; the switches are read live.
import CryptoKit
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSearch
import ObscuraSupport
@testable import ObscuraEngine

actor EngineRecordingIndex: SearchIndexing {
    private(set) var items: [String: SearchItemContent] = [:]
    private(set) var domainsDeleted = 0
    func index(_ items: [SearchItemContent]) async throws { for item in items { self.items[item.uniqueIdentifier] = item } }
    func delete(identifiers: [String]) async throws { for id in identifiers { items[id] = nil } }
    func deleteAll(domain: String) async throws { domainsDeleted += 1; items = [:] }
}

struct SearchRig {
    let root: URL
    let journal: SQLiteJournalStore
    let settings: InMemorySettingsStore
    let index = EngineRecordingIndex()
    let engine: ShieldEngine

    init(settings: Settings = .default) throws {
        root = try Fixture.tempDirectory("search")
        journal = try SQLiteJournalStore(root: root.appendingPathComponent("store", isDirectory: true), ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock(),
                                         backupsRoot: root.appendingPathComponent("backups", isDirectory: true))
        self.settings = InMemorySettingsStore(settings)
        let search = SearchCoordinator(journal: journal, index: index)
        // The rig's root holds its shots and is its screenshot folder (F26: writes go only to watched folders).
        let shots = root
        engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: [Fixture.keyLine, Fixture.plainLine]), journal: journal,
                              settings: self.settings, clock: ManualClock(), folderWatcher: nil, clipboardGuard: nil, search: search,
                              locations: FolderLocations(screenshotFolder: { shots }, downloads: { shots.appendingPathComponent("no-downloads") }))
    }

    func shot() throws -> URL {
        let file = root.appendingPathComponent("Screenshot \(UUID().uuidString.prefix(4)).png")
        try Fixture.pngData().write(to: file)
        return file
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct EngineSearchLabelTests {
    @Test func aCaughtScreenshotIsLabelledByKindNeverByValue() async throws {
        let rig = try SearchRig(); defer { rig.tearDown() }
        let file = try rig.shot()
        let original = try Data(contentsOf: file)
        let outcome = await rig.engine.scan(imageData: original, source: .file, displayName: file.lastPathComponent, filePath: file, origin: .screenshotFolder)
        guard case .redacted(let id, _, _) = outcome else { Issue.record("not redacted: \(outcome)"); return }
        let item = try #require(await rig.index.items[id.uuidString])
        #expect(item.title.hasPrefix("Covered screenshot — "))
        #expect(item.title.contains("Stripe"), "the kind of secret is the label")
        // No 6-character piece of the made-up key, and not its hash, anywhere in the item.
        let everything = item.allText.joined(separator: "\n")
        let key = Array(Fixture.fakeKey)
        for start in 0...(key.count - 6) {
            let piece = String(key[start..<(start + 6)])
            #expect(!everything.contains(piece), "a piece of the made-up key reached the Spotlight item: \(piece)")
        }
        let hash = SHA256.hash(data: Data(Fixture.fakeKey.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(!everything.contains(hash.prefix(12)))
        // The thumbnail is the covered file on disk, not the original.
        #expect(item.thumbnailData == CoveredThumbnail.data(of: file))
        let originalURL = try await rig.journal.originalURL(id)
        #expect(item.thumbnailData != CoveredThumbnail.data(of: originalURL))
        #expect(await rig.engine.searchTarget(for: id.uuidString) == .entry(id))
    }

    @Test func undoRemovesTheLabelAndRedoBringsItBack() async throws {
        var settings = Settings.default
        settings.tagsCoveredFiles = true
        let rig = try SearchRig(settings: settings); defer { rig.tearDown() }
        let file = try rig.shot()
        try FinderTagFiles().setTags(["Work"], on: file)
        let outcome = await rig.engine.scan(imageData: try Data(contentsOf: file), source: .file, displayName: "shot", filePath: file, origin: .screenshotFolder)
        guard case .redacted(let id, _, _) = outcome else { Issue.record("not redacted: \(outcome)"); return }
        let tagged = try FinderTagFiles().tags(of: file)
        #expect(tagged.first == "Work" && tagged.contains("Obscura"), "the person's tag survives the cover and Obscura's is added")

        try await rig.engine.restoreOriginal(id)
        #expect(await rig.index.items[id.uuidString] == nil, "Undo: no Spotlight entry while the original shows")
        #expect(try FinderTagFiles().tags(of: file) == ["Work"], "Undo: Obscura's tags gone, the person's kept")

        try await rig.engine.blackOutAll(id)
        #expect(await rig.index.items[id.uuidString] != nil, "Redo: the entry is back")
        #expect(try FinderTagFiles().tags(of: file).contains("Obscura"))
    }

    @Test func clipboardAndImportCatchesGetNoLabel() async throws {
        let rig = try SearchRig(); defer { rig.tearDown() }
        let clip = await rig.engine.scan(imageData: Fixture.pngData(), source: .clipboard, displayName: "Clipboard", filePath: nil, origin: nil)
        let file = try rig.shot()
        let imported = await rig.engine.scan(imageData: try Data(contentsOf: file), source: .file, displayName: "x", filePath: file, origin: .imported)
        guard case .redacted = clip, case .redacted = imported else { Issue.record("not redacted"); return }
        #expect(await rig.index.items.isEmpty)
        #expect(try await rig.journal.coveredFiles().isEmpty)
    }

    @Test func spotlightOffMakesNoEntry() async throws {
        var settings = Settings.default
        settings.indexesCatchesInSpotlight = false
        let rig = try SearchRig(settings: settings); defer { rig.tearDown() }
        let file = try rig.shot()
        let outcome = await rig.engine.scan(imageData: try Data(contentsOf: file), source: .file, displayName: "x", filePath: file, origin: .screenshotFolder)
        guard case .redacted(let id, _, _) = outcome else { Issue.record("not redacted"); return }
        #expect(await rig.index.items.isEmpty)
        #expect(try await rig.journal.coveredFile(id) != nil, "the record is kept, so switching it on later finds this file")
        #expect(try FinderTagFiles().tags(of: file).isEmpty, "tags are off by default")
    }
}
