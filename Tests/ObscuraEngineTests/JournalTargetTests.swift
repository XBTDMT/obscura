// F26: a path the Journal holds (any process running as the user can change obscura.sqlite) is written or trashed only
// when it is a caught file in a folder watched now, or the exact "(clean)" sibling of one. Every folder here is a
// temporary one; the user's Trash is replaced by a test folder. Every secret is made up.
import Foundation
import Testing
import ObscuraCapture
@testable import ObscuraJournal
import ObscuraPrefs
@testable import ObscuraEngine

@Suite(.serialized) struct JournalTargetTests {
    /// A watched folder with one caught screenshot, and a victim file in a folder that is not watched.
    struct Scene {
        let h: Harness
        let base: URL, watched: URL, outside: URL, file: URL, victim: URL
        let original: Data, victimBytes = Data("made-up victim document".utf8)

        init(settings: Settings = .default) throws {
            h = try Harness(settings: settings)
            base = try Fixture.tempDirectory("f26")
            watched = base.appendingPathComponent("Watched", isDirectory: true)
            outside = base.appendingPathComponent("Outside", isDirectory: true)
            for folder in [watched, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            file = watched.appendingPathComponent("Shot.png")
            victim = outside.appendingPathComponent("Statement.png")
            original = Fixture.pngData()
            try original.write(to: file)
            try victimBytes.write(to: victim)
        }

        func catchIt() async throws -> UUID {
            guard case .redacted(let id, _, _) = await h.scan(original, name: "Shot.png", filePath: file, origin: .watched(watched)) else {
                throw EngineError.journal("not redacted")
            }
            return id
        }

        /// Rewrites a column of the entry's row behind the engine, as another process could.
        func tamper(_ id: UUID, column: String, to value: String) throws {
            let db = try SQLiteConnection(path: h.root.appendingPathComponent(SQLiteJournalStore.databaseName).path)
            defer { db.close() }
            try db.run("UPDATE entries SET \(column) = ? WHERE id = ?", [.text(value), .text(id.uuidString)])
        }

        var victimIntact: Bool { (try? Data(contentsOf: victim)) == victimBytes }
        func tearDown() { h.tearDown(); try? FileManager.default.removeItem(at: base) }
    }

    /// The reported exploit: the entry's file_path is pointed at a file in a folder Obscura does not watch. Undo, Black
    /// Out Again, a finding toggle and a re-render each refuse to write it; the victim keeps its bytes.
    @Test func aFilePathOutsideTheWatchedFoldersIsNeverWritten() async throws {
        let s = try Scene(); defer { s.tearDown() }
        let id = try await s.catchIt()
        // Positive control: with the row as written, Undo writes the caught file.
        try await s.h.engine.restoreOriginal(id)
        #expect(try Data(contentsOf: s.file) == s.original)
        try await s.h.engine.blackOutAll(id)

        try s.tamper(id, column: "file_path", to: s.victim.path)
        await #expect(throws: EngineError.self) { try await s.h.engine.restoreOriginal(id) }
        await #expect(throws: EngineError.self) { try await s.h.engine.blackOutAll(id) }
        let finding = try #require(try await s.h.journal.entry(id).findings.first)
        await #expect(throws: EngineError.self) { try await s.h.engine.setFinding(finding.id, enabled: false, in: id) }
        await #expect(throws: EngineError.self) { try await s.h.engine.rerender(id, style: nil) }
        #expect(s.victimIntact, "a file outside the watched folders was written")
        #expect(try await s.h.journal.uncoveredFiles().isEmpty, "a refused path is never listed as a file to write later")
    }

    /// `..` climbing out of a watched folder, a relative path, and a link inside the watched folder that points out.
    @Test func climbingOutOrALinkIsRefused() async throws {
        let s = try Scene(); defer { s.tearDown() }
        let id = try await s.catchIt()
        try s.tamper(id, column: "file_path", to: s.watched.path + "/../Outside/Statement.png")
        await #expect(throws: EngineError.self) { try await s.h.engine.restoreOriginal(id) }
        try s.tamper(id, column: "file_path", to: "Outside/Statement.png")
        await #expect(throws: EngineError.self) { try await s.h.engine.restoreOriginal(id) }
        let link = s.watched.appendingPathComponent("Link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: s.victim)
        try s.tamper(id, column: "file_path", to: link.path)
        await #expect(throws: EngineError.self) { try await s.h.engine.restoreOriginal(id) }
        #expect(s.victimIntact)
        #expect(JournalPathKind.isLink(link), "the link is still a link")
    }

    /// Keep-both: a clean_copy_path that is not its caught file's own "(clean)" sibling is never trashed.
    @Test func aCleanCopyPathThatIsNotTheSiblingIsNeverTrashed() async throws {
        var settings = Settings.default
        settings.fileHandling = .keepBoth
        let s = try Scene(settings: settings); defer { s.tearDown() }
        let trash = s.base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        await s.h.engine.setTrash { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)) }
        let id = try await s.catchIt()
        let other = s.watched.appendingPathComponent("Other.png")
        try Data("made-up other picture".utf8).write(to: other)
        for path in [s.victim.path, other.path] {
            try s.tamper(id, column: "clean_copy_path", to: path)
            await #expect(throws: EngineError.self) { try await s.h.engine.restoreOriginal(id) }
        }
        #expect(s.victimIntact && FileManager.default.fileExists(atPath: other.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty, "nothing went to the Trash")
    }

    /// A folder the person stops watching: Undo leaves its file alone (the change stays in the Journal).
    @Test func aFolderNoLongerWatchedIsNotWritten() async throws {
        let s = try Scene(); defer { s.tearDown() }
        let id = try await s.catchIt()
        let covered = try Data(contentsOf: s.file)
        s.h.settings.update { $0.extraFolders.removeAll() }
        await #expect(throws: EngineError.self) { try await s.h.engine.restoreOriginal(id) }
        #expect(try Data(contentsOf: s.file) == covered)
    }

    /// An import is never written on disk, Undo included.
    @Test func anImportIsNeverWritten() async throws {
        let s = try Scene(); defer { s.tearDown() }
        let bytes = try Data(contentsOf: s.victim)
        guard case .redacted(let id, _, _) = await s.h.engine.scan(imageData: s.original, source: .imported, displayName: "Statement.png",
                                                                     filePath: s.victim, origin: .imported) else {
            Issue.record("not redacted"); return
        }
        try await s.h.engine.restoreOriginal(id)
        try await s.h.engine.blackOutAll(id)
        #expect(try Data(contentsOf: s.victim) == bytes)
    }

    /// Try Again on a not-covered row whose path is not its entry's file writes nothing.
    @Test func tryAgainWritesOnlyTheEntrysOwnFile() async throws {
        let s = try Scene(); defer { s.tearDown() }
        let id = try await s.catchIt()
        let record = try await s.h.journal.recordUncovered(path: s.victim.path, sourcePath: s.file.path, entryID: id)
        await s.h.engine.loadUnchecked()
        let row = UncoveredFile(record)
        #expect(await s.h.engine.retryUncovered(row) == .notWatched)
        #expect(s.victimIntact)
    }

    /// Check Again on a remembered file trusts the folders watched now, not the origin the row claims: a file outside
    /// them is checked as an import, which never writes it.
    @Test func checkAgainTrustsTheWatchedFoldersNotTheRow() async throws {
        let s = try Scene(); defer { s.tearDown() }
        s.h.watch(s.watched, as: .watched(s.watched))
        _ = try await s.h.journal.recordUnchecked(path: s.victim.path, origin: .screenshotFolder, reason: .ocrTimeout)
        #expect(await s.h.engine.retry(s.victim) == .imported)
        let roots = await s.h.engine.watchedRoots()
        #expect(ShieldEngine.checkedOrigin(of: s.file, stored: .downloads, in: roots) == .watched(s.watched))
        #expect(ShieldEngine.checkedOrigin(of: s.file, stored: .imported, in: roots) == .imported)
    }

    @Test func checkedPathsInUnitForm() throws {
        let base = try Fixture.tempDirectory("f26-unit")
        defer { try? FileManager.default.removeItem(at: base) }
        let roots = [WatchedRoot(url: base, origin: .watched(base))]
        let inside = base.appendingPathComponent("a.png").path
        #expect(JournalTargets.checked(inside, roots: roots)?.path == inside, "a file that does not exist yet may be written")
        #expect(JournalTargets.checked(base.path + "/sub/../a.png", roots: roots) == nil)
        #expect(JournalTargets.checked(base.path + "//a.png", roots: roots) == nil)
        #expect(JournalTargets.checked("a.png", roots: roots) == nil)
        #expect(JournalTargets.checked(base.deletingLastPathComponent().appendingPathComponent("x.png").path, roots: roots) == nil)
        #expect(JournalTargets.checked(base.path, roots: roots) == nil, "a folder is not a file")
    }
}

private enum JournalPathKind {
    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
