// F2: a Journal whose rows or folders were crafted (a copy someone sent, or a file another process changed) never makes
// Obscura delete or write outside its own folders. Every folder here lives in a temporary root; nothing touches the real
// Journal, the Keychain or Preferences.
import CryptoKit
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

private var fm: FileManager { .default }

/// A temporary folder holding `Obscura/` (the Journal root) and `victim/` (what a crafted row aims at), side by side.
private struct Playground {
    let base = fm.temporaryDirectory.appendingPathComponent("obscura-f2-\(UUID().uuidString)", isDirectory: true)
    var root: URL { base.appendingPathComponent("Obscura", isDirectory: true) }
    var victim: URL { base.appendingPathComponent("victim", isDirectory: true) }
    var victimFile: URL { victim.appendingPathComponent("keep.txt") }
    var trash: URL { JournalLocations.images(in: root).appendingPathComponent(SQLiteJournalStore.trashFolderName, isDirectory: true) }

    init() throws {
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("made-up content that must survive".utf8).write(to: victimFile)
    }

    func cleanup() { try? fm.removeItem(at: base) }

    var victimIntact: Bool { fm.fileExists(atPath: victimFile.path) }

    /// Puts a trashed entry row with a raw `id` into the Journal's database, behind the store's back.
    func plantTrashedRow(id: String) throws {
        let db = try SQLiteConnection(path: root.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        defer { db.close() }
        let style = try db.scalarInt("SELECT id FROM styles WHERE is_default = 1")
        try db.run("""
            INSERT INTO entries (id, created_at, source, display_name, container_uti, pixel_width, pixel_height, style_id, trashed_at)
            VALUES (?, '2026-10-28T09:00:00.000Z', 'file', 'Shot.png', 'public.png', 8, 8, ?, '2026-10-28T09:00:00.000Z')
            """, [.text(id), .integer(Int64(style))])
    }

    func trashedRows() throws -> [String] {
        let db = try SQLiteConnection(path: root.appendingPathComponent(SQLiteJournalStore.databaseName).path, readOnly: true)
        defer { db.close() }
        return try db.query("SELECT id FROM entries WHERE trashed_at IS NOT NULL ORDER BY id", []) { $0.string(0) }
    }
}

@Suite struct JournalPathSafetyTests {
    /// The reported exploit: trashed rows whose ids climb out of `.trash` with `../`. Opening the store (which purges the
    /// trash) and an explicit purge delete nothing outside the Journal; the rows stay and the purge reports them.
    @Test func trashedIdsThatClimbOutOfTheTrashDeleteNothing() async throws {
        let p = try Playground(); defer { p.cleanup() }
        _ = try SQLiteJournalStore(root: p.root, ruleKeys: InMemoryRuleKeyStore())
        try fm.createDirectory(at: p.trash, withIntermediateDirectories: true)
        let planted = ["../../../victim", "../../victim", "../victim", "/\(p.victim.path)", "..", "."]
        for id in planted { try p.plantTrashedRow(id: id) }
        // Positive control: the first id really does resolve to the victim folder from the trash.
        #expect(p.trash.appendingPathComponent(planted[0]).standardizedFileURL.path == p.victim.standardizedFileURL.path)

        let store = try SQLiteJournalStore(root: p.root, ruleKeys: InMemoryRuleKeyStore())
        #expect(p.victimIntact, "opening the store deleted a folder outside the Journal")
        await #expect(throws: JournalError.maintenanceIncomplete(step: "trash", failed: planted.count)) { try await store.purgeTrash() }
        #expect(p.victimIntact)
        #expect(try p.trashedRows().sorted() == planted.sorted(), "nothing on disk was touched for them, and their rows stay to be seen")
    }

    /// A real trashed entry next to a planted one still goes: the canonical UUID folder is removed, the row too.
    @Test func aRealTrashedEntryStillGoesNextToAPlantedOne() async throws {
        let p = try Playground(); defer { p.cleanup() }
        let store = try SQLiteJournalStore(root: p.root, ruleKeys: InMemoryRuleKeyStore())
        let entry = try await store.create(NewEntry(source: .file, displayName: "Shot.png", filePath: nil, containerUTI: "public.png",
                                                    pixelWidth: 8, pixelHeight: 8, findings: []),
                                           original: Data([1, 2, 3]), clean: Data([4, 5, 6]))
        try await store.trash([entry.id])
        #expect(fm.fileExists(atPath: p.trash.appendingPathComponent(entry.id.uuidString).path))
        try p.plantTrashedRow(id: "../../../victim")
        await #expect(throws: JournalError.maintenanceIncomplete(step: "trash", failed: 1)) { try await store.purgeTrash() }
        #expect(!fm.fileExists(atPath: p.trash.appendingPathComponent(entry.id.uuidString).path))
        #expect(try p.trashedRows() == ["../../../victim"])
        #expect(p.victimIntact)
    }

    /// `.trash` shipped as a link to another folder: the Journal refuses to open, and a link that appears later is
    /// never entered by a purge.
    @Test func aTrashFolderThatIsALinkIsNeverEntered() async throws {
        let p = try Playground(); defer { p.cleanup() }
        let store = try SQLiteJournalStore(root: p.root, ruleKeys: InMemoryRuleKeyStore())
        try? fm.removeItem(at: p.trash)
        try fm.createSymbolicLink(at: p.trash, withDestinationURL: p.victim)
        // Positive control: through the link, the victim's file is visible.
        #expect(try fm.contentsOfDirectory(atPath: p.trash.path) == ["keep.txt"])

        await #expect(throws: JournalError.maintenanceIncomplete(step: "trash", failed: 1)) { try await store.purgeTrash() }
        #expect(p.victimIntact)
        #expect(throws: JournalError.unsafeLocation("trash folder")) { try SQLiteJournalStore(root: p.root, ruleKeys: InMemoryRuleKeyStore()) }
        #expect(p.victimIntact)
        await #expect(throws: JournalError.unsafeLocation("trash folder")) { try await store.trash([UUID()]) }
        await #expect(throws: JournalError.maintenanceIncomplete(step: "orphans", failed: 1)) { try await store.sweepOrphans() }
        #expect(p.victimIntact)
    }

    /// A link to a folder, sitting inside the trash, is removed as a link: what it points at survives.
    @Test func aLinkInsideTheTrashGoesButNotItsTarget() async throws {
        let p = try Playground(); defer { p.cleanup() }
        let store = try SQLiteJournalStore(root: p.root, ruleKeys: InMemoryRuleKeyStore())
        try fm.createDirectory(at: p.trash, withIntermediateDirectories: true)
        let id = UUID()
        try fm.createSymbolicLink(at: p.trash.appendingPathComponent(id.uuidString), withDestinationURL: p.victim)
        try p.plantTrashedRow(id: id.uuidString)
        try await store.purgeTrash()
        #expect(p.victimIntact)
        #expect(JournalPathSafety.kind(p.trash.appendingPathComponent(id.uuidString)) == .missing)
    }

    /// The root itself, the images folder, or the database file as a link: the Journal refuses to open.
    @Test func linkedRootImagesFolderOrDatabaseAreRefused() throws {
        let p = try Playground(); defer { p.cleanup() }
        try fm.createSymbolicLink(at: p.root, withDestinationURL: p.victim)
        #expect(throws: JournalError.unsafeLocation("folder")) { try SQLiteJournalStore(root: p.root, ruleKeys: InMemoryRuleKeyStore()) }
        try fm.removeItem(at: p.root)

        try fm.createDirectory(at: p.root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: JournalLocations.images(in: p.root), withDestinationURL: p.victim)
        #expect(throws: JournalError.unsafeLocation("images folder")) { try SQLiteJournalStore(root: p.root, ruleKeys: InMemoryRuleKeyStore()) }
        try fm.removeItem(at: JournalLocations.images(in: p.root))

        let elsewhere = p.victim.appendingPathComponent("other.sqlite")
        try fm.createSymbolicLink(at: p.root.appendingPathComponent(SQLiteJournalStore.databaseName), withDestinationURL: elsewhere)
        #expect(throws: JournalError.unsafeLocation("database")) { try SQLiteJournalStore(root: p.root, ruleKeys: InMemoryRuleKeyStore()) }
        #expect(!fm.fileExists(atPath: elsewhere.path), "the database was created through the link")
        #expect(p.victimIntact)
    }

    /// The CLI's inspection reads a crafted Journal without changing a byte under its root: no purge, no migration, no
    /// folder made, no key asked to be created.
    @Test func theInspectionChangesNothingUnderACraftedRoot() throws {
        let p = try Playground(); defer { p.cleanup() }
        try RuleFixtures.makeVersionSevenJournal(at: p.root)          // schema 7: a store would migrate and seal it
        try p.plantTrashedRow(id: "../victim")
        try fm.createDirectory(at: p.trash, withIntermediateDirectories: true)
        let before = try Self.snapshot(p.root)

        let inspector = try JournalInspector(root: p.root)
        #expect(inspector.schemaVersion == 7)
        #expect(try inspector.liveEntries().count == 1)
        let keys = RecordingKeyStore()
        let rules = try inspector.rules(ruleKeys: keys)
        #expect(rules.map(\.id) == RuleFixtures.rules.map(\.id))
        #expect(rules.allSatisfy { $0.state == .notSealedYet })
        #expect(keys.created == 0)

        #expect(try Self.snapshot(p.root) == before, "the inspection changed a file under the root")
        #expect(p.victimIntact)
        #expect(try p.trashedRows() == ["../victim"])
    }

    /// Sealed rules are listed as readable or not, with the key the key store already holds; none is created.
    @Test func theInspectionOpensSealedRulesWithoutCreatingAKey() async throws {
        let p = try Playground(); defer { p.cleanup() }
        let keys = InMemoryRuleKeyStore()
        do {
            let store = try SQLiteJournalStore(root: p.root, ruleKeys: keys)
            try await store.upsertRule(RuleFixtures.rules[0])
        }
        let inspector = try JournalInspector(root: p.root)
        #expect(try inspector.rules(ruleKeys: keys).map(\.state) == [.readable])
        #expect(try inspector.rules(ruleKeys: InMemoryRuleKeyStore(key: SymmetricKey(size: .bits256))).map(\.state) == [.unreadable(.otherKey)])
        let empty = RecordingKeyStore()
        #expect(try inspector.rules(ruleKeys: empty).map(\.state) == [.unreadable(.keyMissing)])
        #expect(empty.created == 0)
    }

    @Test func aFolderThatIsNotAJournalIsRefused() throws {
        let p = try Playground(); defer { p.cleanup() }
        #expect(throws: (any Error).self) { try JournalInspector(root: p.victim) }
        #expect(!fm.fileExists(atPath: p.victim.appendingPathComponent(SQLiteJournalStore.databaseName).path))
    }

    /// Every regular file under `root` with its bytes, and every folder and link, by relative path. SQLite's own `-wal`
    /// and `-shm` files are left out: any reader of a WAL database (the read-only one too) makes them; the database file
    /// itself is compared byte for byte.
    static func snapshot(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let base = root.standardizedFileURL.path
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) ?? .init() {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            if relative.hasSuffix("-wal") || relative.hasSuffix("-shm") { continue }
            switch JournalPathSafety.kind(url) {
            case .directory: out[relative + "/"] = Data()
            case .symbolicLink: out[relative + "@"] = Data()
            default: out[relative] = try Data(contentsOf: url)
            }
        }
        return out
    }
}

/// A key store that never holds a key and counts creations.
private final class RecordingKeyStore: RuleKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var creates = 0
    var created: Int { lock.withLock { creates } }
    func key(id: Data) throws -> SymmetricKey? { nil }
    func store(_ key: SymmetricKey, id: Data) throws { lock.withLock { creates += 1 } }
    func storedKeyIDs() throws -> Set<Data> { [] }
    func removeKey(id: Data) throws {}
}
