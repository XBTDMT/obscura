// G-23: the images folder is `Journal.noindex`, excluded from Time Machine; a pre-G-23 Journal moves there once, with
// a backup, crash-safe and idempotent; nothing in the code still names the old folder.
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

/// A store root and its own backups folder inside one temp folder, removed afterwards.
struct LayoutRoot {
    /// Under the package's `.build` folder, not the system temp folder: Time Machine already excludes all of
    /// `/private/var/folders`, so `tmutil isexcluded` there could not tell Obscura's flag from the system's.
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/obscura-layout-tests/\(UUID().uuidString)", isDirectory: true)
    var root: URL { base.appendingPathComponent("Obscura", isDirectory: true) }
    var backups: URL { base.appendingPathComponent("Obscura-Backups", isDirectory: true) }
    var legacy: URL { root.appendingPathComponent("Journal", isDirectory: true) }
    var current: URL { root.appendingPathComponent("Journal.noindex", isDirectory: true) }
    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func open(clock: ManualClock = ManualClock(), fault: JournalLayoutMigration.Fault? = nil) throws -> SQLiteJournalStore {
        try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore(), clock: clock, backupsRoot: backups, layoutFault: fault)
    }

    /// A Journal as Obscura wrote it before G-23: entries created through the store, then the images folder put back
    /// at its old name, exactly the layout an installed older build leaves.
    func makeLegacy(entries n: Int, trashed: Int = 0, clock: ManualClock = ManualClock()) async throws -> [UUID] {
        var ids: [UUID] = []
        do {
            let store = try open(clock: clock)
            for i in 0..<n {
                let e = try await store.create(NewEntry(source: .file, displayName: "Shot \(i).png", filePath: "/home/x/Desktop/Shot \(i).png",
                                                        containerUTI: "public.png", pixelWidth: 10, pixelHeight: 10,
                                                        findings: [NewFinding(lineIndex: 0, rect: CGRect(x: 1, y: 1, width: 2, height: 2),
                                                                              detectorIDs: ["fake.token"], category: "ai")]),
                                               original: Data("original-\(i)".utf8), clean: Data("clean-\(i)".utf8))
                ids.append(e.id)
            }
            if trashed > 0 { try await store.trash(Array(ids.prefix(trashed))) }
        }
        try FileManager.default.moveItem(at: current, to: legacy)
        return ids
    }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private struct InjectedFailure: Error {}

private func layoutBackups(_ r: LayoutRoot) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: r.backups, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix("-before-journal-noindex.noindex") }
}

/// What `tmutil isexcluded` says about `url`, or nil when the tool cannot answer.
private func tmutilSaysExcluded(_ url: URL) -> Bool? {
    let tool = URL(fileURLWithPath: "/usr/bin/tmutil")
    guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
    let process = Process()
    process.executableURL = tool
    process.arguments = ["isexcluded", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if out.contains("[Excluded]") { return true }
    if out.contains("[Included]") { return false }
    return nil
}

/// Time Machine's own answer when it can give one that means something (the tool is there and the test folder is not
/// already excluded as a whole); the flag Obscura sets otherwise.
private func timeMachineExcludes(_ url: URL, base: URL) -> Bool {
    guard tmutilSaysExcluded(base.deletingLastPathComponent()) == false, let answer = tmutilSaysExcluded(url) else {
        return BackupExclusion.isExcluded(url)
    }
    return answer
}

@Suite struct JournalLayoutTests {
    @Test func freshInstallUsesTheNoindexFolderExcludedFromBackup() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        let store = try r.open()
        #expect(store.journalRoot == r.current)
        #expect(SQLiteJournalStore.journalFolderName == "Journal.noindex")
        #expect(exists(r.current) && !exists(r.legacy), "no old-style folder is ever made")
        #expect(timeMachineExcludes(r.current, base: r.base), "the images folder is excluded from Time Machine")
        #expect(!timeMachineExcludes(r.root, base: r.base) && !BackupExclusion.isExcluded(r.root), "the database folder stays backed up (rules and settings are the person's work)")
        #expect(!exists(r.backups), "nothing to back up on a fresh install")
        #expect(store.layoutMigration.outcome == .nothingToMove)
        let e = try await store.create(NewEntry(source: .file, displayName: "a", containerUTI: "public.png", pixelWidth: 1, pixelHeight: 1, findings: []),
                                       original: Data([1]), clean: Data([2]))
        #expect(try await store.originalURL(e.id).path.hasPrefix(r.current.path + "/"))
    }

    @Test func theExclusionIsReappliedAtEveryLaunch() throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        _ = try r.open()
        // Something (a restore, a copy) dropped the attribute.
        removexattr(r.current.path, "com.apple.metadata:com_apple_backup_excludeItem", 0)
        #expect(!BackupExclusion.isExcluded(r.current))
        _ = try r.open()
        #expect(BackupExclusion.isExcluded(r.current))
    }

    @Test func anOldJournalMovesWithABackupThatIsVerifiedExcludedAndNoindex() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        let ids = try await r.makeLegacy(entries: 5)
        let store = try r.open()
        #expect(store.layoutMigration.outcome == .migrated)
        #expect(store.layoutMigration.foldersMoved == 5)
        #expect(store.layoutMigration.filesVerified == 10)
        #expect(store.layoutMigration.entriesInDatabase == 5)
        #expect(!exists(r.legacy), "the old folder is gone")
        for (i, id) in ids.enumerated() {
            #expect(try await store.originalData(id) == Data("original-\(i)".utf8), "byte-identical after the move")
            #expect(try await store.cleanData(id) == Data("clean-\(i)".utf8))
        }
        #expect(try await store.entries(matching: .live).count == 5)
        #expect(try await store.sweepStale() == 0, "nothing looks stale after the move")
        let backups = try layoutBackups(r)
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(backup.lastPathComponent.hasSuffix(".noindex"))
        #expect(timeMachineExcludes(backup, base: r.base) && timeMachineExcludes(r.backups, base: r.base), "the backup holds originals: never backed up")
        #expect(exists(backup.appendingPathComponent("obscura.sqlite")), "a consistent copy of the database is in the backup")
        let manifest = try JournalLayoutMigration.manifest(at: backup)
        #expect(manifest.state == .verified && manifest.files.count == 10 && manifest.folders == 5)
    }

    @Test func trashedEntriesMoveToo() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        let ids = try await r.makeLegacy(entries: 3, trashed: 1)
        // The first open of a store purges the trash, so build the trashed folder by hand into the old layout.
        let trashed = r.legacy.appendingPathComponent(".trash/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        try Data("t".utf8).write(to: trashed.appendingPathComponent("original.png"))
        let store = try r.open()
        #expect(store.layoutMigration.outcome == .migrated)
        #expect(try await store.entries(matching: .live).map(\.id).sorted { $0.uuidString < $1.uuidString } == Array(ids.dropFirst()).sorted { $0.uuidString < $1.uuidString })
    }

    @Test func rerunningIsANoOp() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        _ = try await r.makeLegacy(entries: 2)
        _ = try r.open()
        let second = try r.open()
        #expect(second.layoutMigration.outcome == .nothingToMove)
        #expect(try layoutBackups(r).count == 1, "no second backup")
    }

    @Test func aMigrationStoppedAfterTheBackupLeavesAReadableJournalAndResumes() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        let ids = try await r.makeLegacy(entries: 3)
        let failing = try r.open(fault: { step in if step == .backupCopied { throw InjectedFailure() } })
        guard case .failed = failing.layoutMigration.outcome else { Issue.record("expected a failure"); return }
        #expect(exists(r.legacy), "nothing moved")
        // Readable: every entry's images come from the old folder, and none is swept as stale.
        for (i, id) in ids.enumerated() { #expect(try await failing.originalData(id) == Data("original-\(i)".utf8)) }
        #expect(try await failing.sweepStale() == 0)

        let next = try r.open()
        #expect(next.layoutMigration.outcome == .migrated)
        #expect(!exists(r.legacy))
        #expect(try layoutBackups(r).count == 1, "the first backup is reused, not copied again")
        for (i, id) in ids.enumerated() { #expect(try await next.originalData(id) == Data("original-\(i)".utf8)) }
    }

    /// Between a stopped launch and the next, the Journal keeps working from the old folder: an entry is deleted, one is
    /// re-rendered, a new one is caught. The resumed migration verifies what is owed and is not fooled by either.
    @Test func workDoneWhileStoppedDoesNotFailTheResumedVerify() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        let clock = ManualClock()
        let ids = try await r.makeLegacy(entries: 3, clock: clock)
        do {
            let stopped = try r.open(clock: clock, fault: { step in if step == .backupCopied { throw InjectedFailure() } })
            try await stopped.trash([ids[0]])
            try await stopped.purgeTrash()
            let rerendered = try await stopped.entry(ids[1])
            _ = try await stopped.commitRender(ids[1], clean: Data("re-rendered".utf8), enabled: Set(rerendered.enabledFindings.map(\.id)), style: nil,
                                           expectedRevision: rerendered.revision)
            _ = try await stopped.create(NewEntry(source: .file, displayName: "new", containerUTI: "public.png", pixelWidth: 1, pixelHeight: 1, findings: []),
                                         original: Data([1]), clean: Data([2]))
        }
        let next = try r.open(clock: clock)
        #expect(next.layoutMigration.outcome == .migrated)
        #expect(!exists(r.legacy))
        #expect(try await next.cleanData(ids[1]) == Data("re-rendered".utf8))
        #expect(try await next.originalData(ids[2]) == Data("original-2".utf8))
        #expect(try await next.entries(matching: .live).count == 3)
    }

    @Test func aMigrationStoppedPartWayThroughAMergeStaysReadableAndFinishes() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        let ids = try await r.makeLegacy(entries: 4)
        // The new folder exists already (for example a launch whose backup copy failed made it), so entries move one by one.
        try FileManager.default.createDirectory(at: r.current, withIntermediateDirectories: true)
        let failing = try r.open(fault: { step in if step == .movedOne(2) { throw InjectedFailure() } })
        guard case .failed = failing.layoutMigration.outcome else { Issue.record("expected a failure"); return }
        #expect(exists(r.legacy) && exists(r.current), "half moved")
        for (i, id) in ids.enumerated() { #expect(try await failing.originalData(id) == Data("original-\(i)".utf8), "readable from either folder") }
        #expect(try await failing.sweepStale() == 0, "nothing swept while half moved")

        let next = try r.open()
        #expect(next.layoutMigration.outcome == .migrated)
        #expect(next.layoutMigration.filesVerified == 8)
        #expect(!exists(r.legacy))
        for (i, id) in ids.enumerated() { #expect(try await next.originalData(id) == Data("original-\(i)".utf8)) }
    }

    @Test func aCrashAfterTheMoveIsVerifiedAtTheNextLaunch() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        _ = try await r.makeLegacy(entries: 2)
        let failing = try r.open(fault: { step in if step == .moved { throw InjectedFailure() } })
        guard case .failed = failing.layoutMigration.outcome else { Issue.record("expected a failure"); return }
        #expect(try JournalLayoutMigration.manifest(at: try #require(try layoutBackups(r).first)).state == .copied)
        let next = try r.open()
        #expect(next.layoutMigration.outcome == .migrated)
        #expect(try JournalLayoutMigration.manifest(at: try #require(try layoutBackups(r).first)).state == .verified)
    }

    @Test func aPartialBackupFromACrashDuringTheCopyIsDiscarded() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        _ = try await r.makeLegacy(entries: 1)
        let partial = r.backups.appendingPathComponent("2026-01-01-000000.partial.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let store = try r.open()
        #expect(store.layoutMigration.outcome == .migrated)
        #expect(!exists(partial))
    }

    @Test func aDifferingCopyIsAConflictThatKeepsBothAndTheBackup() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        let ids = try await r.makeLegacy(entries: 1)
        let clash = r.current.appendingPathComponent(ids[0].uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: clash, withIntermediateDirectories: true)
        try Data("something else".utf8).write(to: clash.appendingPathComponent("original.png"))
        let store = try r.open()
        guard case .failed = store.layoutMigration.outcome else { Issue.record("expected a conflict"); return }
        #expect(exists(r.legacy.appendingPathComponent(ids[0].uuidString)), "the old copy is not thrown away")
        #expect(try layoutBackups(r).count == 1)
    }

    @Test func theVerifiedBackupGoesAfterTheRetentionWindowAndDeleteAllTakesItToo() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        let clock = ManualClock()
        _ = try await r.makeLegacy(entries: 1, clock: clock)
        let store = try r.open(clock: clock)
        _ = try await store.pruneExpired(olderThan: .seconds(24 * 3600))
        #expect(try layoutBackups(r).count == 1, "kept inside the window")
        clock.advance(by: 25 * 3600)
        _ = try await store.pruneExpired(olderThan: .seconds(24 * 3600))
        #expect(try layoutBackups(r).isEmpty, "gone once originals of that age would be gone")

        // A failed backup is never pruned by age, but Delete All Originals removes every copy.
        let r2 = LayoutRoot(); defer { r2.cleanup() }
        _ = try await r2.makeLegacy(entries: 1, clock: clock)
        let kept = try r2.open(clock: clock, fault: { step in if step == .backupCopied { throw InjectedFailure() } })
        clock.advance(by: 30 * 24 * 3600)
        _ = try await kept.pruneExpired(olderThan: .seconds(3600))
        #expect(try layoutBackups(r2).count == 1, "an unfinished migration's backup is kept")
        try await kept.deleteAll()
        #expect(try layoutBackups(r2).isEmpty && !exists(r2.legacy))
    }

    @Test func otherFoldersInObscuraBackupsAreNeverTouched() async throws {
        let r = LayoutRoot(); defer { r.cleanup() }
        let clock = ManualClock()
        let manual = r.backups.appendingPathComponent("2026-10-27-before-schema-2", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        _ = try await r.makeLegacy(entries: 1, clock: clock)
        let store = try r.open(clock: clock)
        clock.advance(by: 60 * 24 * 3600)
        _ = try await store.pruneExpired(olderThan: .seconds(3600))
        try await store.deleteAll()
        #expect(exists(manual))
        #expect(timeMachineExcludes(r.backups, base: r.base), "the folder that holds every Journal copy is out of Time Machine")
    }
}

/// Fails if any source file builds a path to the old `Journal` images folder instead of going through
/// `JournalLocations` / `SQLiteJournalStore.journalRoot` (G-23).
@Suite struct NoOldJournalPathTests {
    @Test func noSourceSpellsTheOldFolder() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let patterns = [
            #"(appendingPathComponent|appending\(path:|appending\(component:)\s*\(?\s*"Journal"\s*[,)]"#,
            #""Journal/"#,
            #"/Journal/"#,
            #"Application Support/Obscura/Journal(?!\.noindex)"#,
        ].map { try! NSRegularExpression(pattern: $0) }
        var offenders: [String] = []
        var scanned = 0
        for folder in ["Sources", "Apps", "Tools"] {
            guard let walker = FileManager.default.enumerator(at: repo.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for (n, line) in text.components(separatedBy: "\n").enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    if patterns.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                        offenders.append("\(url.lastPathComponent):\(n + 1)")
                    }
                }
            }
        }
        #expect(scanned > 100, "the scan saw the sources")
        #expect(offenders.isEmpty, "old Journal path in: \(offenders)")
        #expect(JournalLocations.legacyImagesFolderName == "Journal", "the one place the old name lives")
    }
}
