public import Foundation
import ObscuraSupport

/// Where the Journal's files live (G-23). Every reader and writer of a Journal path goes through these names or through
/// `SQLiteJournalStore.journalRoot`; a test fails if any source file spells the old folder another way.
///
/// ```
/// ~/Library/Application Support/
/// ├── Obscura/                         0700  the store's root (backed up: rules, settings, rects, ids, no image)
/// │   ├── obscura.sqlite
/// │   └── Journal.noindex/             0700  originals and covered copies: never indexed (.noindex), never backed up
/// └── Obscura-Backups/                       excluded from backup: every folder in it is a copy of a Journal
///     └── <stamp>-before-journal-noindex.noindex/   the layout migration's own copy, pruned after the retention window
/// ```
public enum JournalLocations {
    /// The folder of entry images. Spotlight never indexes a folder whose name ends in `.noindex`.
    public static let imagesFolderName = "Journal.noindex"
    /// The images folder before G-23. Only the layout migration reads it, to move what it holds.
    static let legacyImagesFolderName = "Journal"
    /// Sibling of the store's root that holds copies of a Journal taken before a migration.
    public static let backupsFolderName = "Obscura-Backups"
    /// Suffix of the folders the layout migration writes into `backupsFolderName`; the only ones it ever prunes.
    static let layoutBackupSuffix = "-before-journal-noindex.noindex"
    static let partialBackupSuffix = ".partial.noindex"
    static let manifestName = "manifest.json"

    /// `~/Library/Application Support/Obscura`: the app's store root (not created here).
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base.appending(path: "Obscura", directoryHint: .isDirectory)
    }

    public static func images(in root: URL) -> URL { root.appending(path: imagesFolderName, directoryHint: .isDirectory) }
    static func legacyImages(in root: URL) -> URL { root.appending(path: legacyImagesFolderName, directoryHint: .isDirectory) }
    public static func backups(besides root: URL) -> URL {
        root.deletingLastPathComponent().appending(path: backupsFolderName, directoryHint: .isDirectory)
    }
}

/// Keeps a folder out of Time Machine. `isExcludedFromBackup` is sticky (an extended attribute on the folder, so it
/// survives a move or rename); it is still set again at every launch because it costs one call and a restore from an
/// older backup or a copy by another tool can drop it.
public enum BackupExclusion {
    public static func exclude(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }

    public static func isExcluded(_ url: URL) -> Bool {
        var target = url
        target.removeAllCachedResourceValues()
        return (try? target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }
}

/// What the layout migration's backup holds and how far the migration got. Paths are relative to the images folder
/// (`<UUID>/original.png`), never anything recognized: the manifest is as safe to read as a folder listing.
struct LayoutBackupManifest: Codable, Equatable {
    enum State: String, Codable { case copied, verified, failed }
    struct File: Codable, Equatable { let path: String; let size: Int64 }

    var format = 1
    var createdAt: Date
    var state: State
    /// Entry folders copied (top-level `<UUID>` folders plus `.trash/<UUID>` ones).
    var folders: Int
    var files: [File]
    /// Entry rows in the database when the backup was taken.
    var entriesInDatabase: Int
    /// Each entry's `revision` when the backup was taken. A clean image is rewritten (and its revision bumped) by a
    /// re-render; an original never changes. So a resumed migration verifies an original byte for byte always, and a
    /// clean image byte for byte unless its entry was re-rendered since the copy.
    var revisions: [String: Int] = [:]
    var verifiedAt: Date?
    var failure: String?

    enum CodingKeys: String, CodingKey {
        case format, createdAt = "created_at", state, folders, files, entriesInDatabase = "entries_in_database", revisions,
             verifiedAt = "verified_at", failure
    }
}

/// The one-time move of the images from `Journal/` to `Journal.noindex/` (G-23), crash-safe and idempotent:
///
/// 1. Copy the old images folder and a consistent copy of the database (`VACUUM INTO`) into a `.partial.noindex` folder
///    in `Obscura-Backups/`, write its manifest, then rename it to its final `…-before-journal-noindex.noindex` name.
///    A crash during the copy leaves only a partial folder, which the next launch deletes and copies again.
/// 2. Move the images: one `rename(2)` of the whole folder when the new one does not exist yet (nothing is ever half
///    moved), else entry by entry (each a same-volume rename), keeping whichever copy is byte-identical.
/// 3. Verify against the backup: every file is at its new place with the same bytes, the old folder is gone, and every
///    entry row that had a folder still has one. Only then is the manifest marked `verified`.
///
/// Any failure is logged (counts only) and leaves the backup in place and the Journal readable: the store looks in
/// the old folder for an entry the new one does not hold yet, and the next launch picks up where this one stopped.
/// A verified backup is deleted once the retention window has passed (`pruneVerifiedBackups`); a failed one is kept.
struct JournalLayoutMigration {
    /// Points where a test can make the migration fail, to prove the Journal survives it.
    enum Step: Equatable, Sendable {
        case backupCopied
        case movedOne(Int)
        case moved
    }
    typealias Fault = @Sendable (Step) throws -> Void

    enum Outcome: Equatable {
        case nothingToMove
        case migrated
        case failed(String)
    }

    struct Report: Equatable {
        var outcome: Outcome
        var foldersMoved = 0
        var filesVerified = 0
        var entriesInDatabase = 0
        var backup: URL?
    }

    let root: URL
    let backupsRoot: URL
    let now: Date
    let fault: Fault?

    private var fm: FileManager { .default }
    private var legacy: URL { JournalLocations.legacyImages(in: root) }
    private var current: URL { JournalLocations.images(in: root) }

    func run(db: SQLiteConnection) -> Report {
        var report = Report(outcome: .nothingToMove)
        do {
            let legacyExists = fm.fileExists(atPath: legacy.path)
            var pending = try pendingBackup()
            if !legacyExists && pending == nil { return report }
            try FileAtomics.makePrivateDirectory(backupsRoot)
            try BackupExclusion.exclude(backupsRoot)
            if legacyExists {
                if pending == nil { pending = try makeBackup(db: db) }
                try fault?(.backupCopied)
                report.foldersMoved = try moveImages()
                try fault?(.moved)
            }
            guard let backup = pending else { return report }
            report.backup = backup
            report = try verify(backup: backup, db: db, report: report)
        } catch {
            report.outcome = .failed(String(describing: type(of: error)))
            if let backup = report.backup ?? (try? pendingBackup()) { markFailed(backup, reason: "interrupted") }
            Log.journal.error("journal layout migration stopped; the old folder stays readable and the next launch resumes")
        }
        return report
    }

    // MARK: Backup

    /// The newest backup whose migration has not finished (state `copied`), if any.
    private func pendingBackup() throws -> URL? {
        guard fm.fileExists(atPath: backupsRoot.path) else { return nil }
        let candidates = try fm.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(JournalLocations.layoutBackupSuffix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in candidates {
            if let manifest = try? Self.manifest(at: url), manifest.state == .copied { return url }
        }
        return nil
    }

    private func makeBackup(db: SQLiteConnection) throws -> URL {
        // A partial copy from an interrupted launch is discarded: nothing was moved before its copy finished.
        for url in try fm.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasSuffix(JournalLocations.partialBackupSuffix) {
            try fm.removeItem(at: url)
        }
        let stamp = Self.stamp(now)
        let partial = backupsRoot.appending(path: stamp + JournalLocations.partialBackupSuffix, directoryHint: .isDirectory)
        try FileAtomics.makePrivateDirectory(partial)
        try BackupExclusion.exclude(partial)
        let images = partial.appending(path: JournalLocations.legacyImagesFolderName, directoryHint: .isDirectory)
        try fm.copyItem(at: legacy, to: images)
        try db.exec("VACUUM INTO '\(partial.appending(path: SQLiteJournalStore.databaseName).path.replacingOccurrences(of: "'", with: "''"))'")
        let files = try Self.files(under: images)
        let revisions: [(String, Int)] = try db.query("SELECT id, revision FROM entries") { ($0.string(0), $0.int(1)) }
        let manifest = LayoutBackupManifest(createdAt: now, state: .copied, folders: try Self.entryFolders(under: images).count,
                                            files: files, entriesInDatabase: revisions.count,
                                            revisions: Dictionary(revisions, uniquingKeysWith: { a, _ in a }))
        try Self.write(manifest, to: partial)
        var final = backupsRoot.appending(path: stamp + JournalLocations.layoutBackupSuffix, directoryHint: .isDirectory)
        var n = 2
        while fm.fileExists(atPath: final.path) {
            final = backupsRoot.appending(path: "\(stamp)-\(n)" + JournalLocations.layoutBackupSuffix, directoryHint: .isDirectory)
            n += 1
        }
        try fm.moveItem(at: partial, to: final)
        Log.journal.info("journal layout backup written folders=\(manifest.folders) files=\(files.count) entries=\(manifest.entriesInDatabase)")
        return final
    }

    // MARK: Move

    /// Returns the number of entry folders now in the new place that came from the old one.
    private func moveImages() throws -> Int {
        let moved = try Self.entryFolders(under: legacy).count
        if !fm.fileExists(atPath: current.path) {
            try fm.moveItem(at: legacy, to: current)   // one rename(2): the old layout or the new, never half of each
            return moved
        }
        // The new folder exists already (an earlier launch stopped part-way, or created it before a failed copy):
        // move entry by entry. `.trash` is merged one level down so a trashed entry keeps its place.
        var count = 0
        for (from, to) in try mergePairs() {
            if fm.fileExists(atPath: to.path) {
                guard try Self.sameTree(from, to) else { throw MigrationError.conflict }
                try fm.removeItem(at: from)
            } else {
                try FileAtomics.makePrivateDirectory(to.deletingLastPathComponent())
                try fm.moveItem(at: from, to: to)
            }
            count += 1
            try fault?(.movedOne(count))
        }
        let trash = legacy.appending(path: SQLiteJournalStore.trashFolderName, directoryHint: .isDirectory)
        if fm.fileExists(atPath: trash.path), try fm.contentsOfDirectory(atPath: trash.path).isEmpty { try fm.removeItem(at: trash) }
        let left = try fm.contentsOfDirectory(atPath: legacy.path).filter { $0 != ".DS_Store" }
        guard left.isEmpty else { throw MigrationError.conflict }
        try fm.removeItem(at: legacy)
        return count
    }

    private func mergePairs() throws -> [(URL, URL)] {
        var pairs: [(URL, URL)] = []
        for name in try fm.contentsOfDirectory(atPath: legacy.path).sorted() where name != ".DS_Store" {
            if name == SQLiteJournalStore.trashFolderName {
                let trash = legacy.appending(path: name, directoryHint: .isDirectory)
                for child in try fm.contentsOfDirectory(atPath: trash.path).sorted() where child != ".DS_Store" {
                    pairs.append((trash.appending(path: child), current.appending(path: name).appending(path: child)))
                }
            } else {
                pairs.append((legacy.appending(path: name), current.appending(path: name)))
            }
        }
        return pairs
    }

    // MARK: Verify

    private func verify(backup: URL, db: SQLiteConnection, report: Report) throws -> Report {
        var report = report
        var manifest = try Self.manifest(at: backup)
        let copy = backup.appending(path: JournalLocations.legacyImagesFolderName, directoryHint: .isDirectory)
        var problems: [String] = []
        if fm.fileExists(atPath: legacy.path) { problems.append("old folder still present") }
        var verified = 0
        let revisions = Dictionary(try db.query("SELECT id, revision FROM entries") { ($0.string(0), $0.int(1)) }, uniquingKeysWith: { a, _ in a })
        let rows = Array(revisions.keys)
        for file in manifest.files {
            let moved = current.appending(path: file.path)
            let kept = copy.appending(path: file.path)
            // Between a stopped launch and this one the person or retention may have deleted an entry (its row is gone
            // with it): its files are not owed. Everything else must be in the new place.
            let id = Self.entryID(of: file.path)
            if let id, revisions[id] == nil { continue }
            guard fm.fileExists(atPath: moved.path) else { problems.append("missing"); continue }
            let isClean = (file.path as NSString).lastPathComponent.hasPrefix("clean.")
            let rerendered = isClean && id.map { revisions[$0] != manifest.revisions[$0] } == true
            if !rerendered {
                guard try Self.sameBytes(moved, kept) else { problems.append("differs"); continue }
            }
            verified += 1
        }
        // Every entry row whose folder was copied has its folder in the new place.
        let copiedFolders = Set(try Self.entryFolders(under: copy).map(\.name))
        report.entriesInDatabase = rows.count
        let lost = rows.filter { copiedFolders.contains($0) && !Self.hasFolder(id: $0, in: current) }
        if !lost.isEmpty { problems.append("\(lost.count) entries lost their folder") }
        report.filesVerified = verified
        if report.foldersMoved == 0 { report.foldersMoved = copiedFolders.count }

        if problems.isEmpty {
            manifest.state = .verified
            manifest.verifiedAt = now
            try Self.write(manifest, to: backup)
            report.outcome = .migrated
            Log.journal.info("journal layout migrated folders=\(report.foldersMoved) files=\(verified) entries=\(rows.count)")
        } else {
            manifest.state = .failed
            manifest.failure = problems.first
            try Self.write(manifest, to: backup)
            report.outcome = .failed(problems.joined(separator: "; "))
            Log.journal.error("journal layout verify failed problems=\(problems.count) files=\(verified) of \(manifest.files.count); backup kept")
        }
        return report
    }

    private func markFailed(_ backup: URL, reason: String) {
        // An interruption is not a verify failure: the backup stays `copied`, so the next launch resumes it. Only the
        // reason is noted, for whoever reads the manifest.
        guard var manifest = try? Self.manifest(at: backup), manifest.state == .copied else { return }
        manifest.failure = reason
        try? Self.write(manifest, to: backup)
    }

    // MARK: Pruning

    /// Deletes this store's verified layout backups taken before `cutoff`. A failed or unfinished one is kept, and no
    /// other folder in `Obscura-Backups` is ever touched. Returns the count.
    static func pruneVerifiedBackups(in backupsRoot: URL, takenBefore cutoff: Date) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupsRoot.path) else { return 0 }
        var removed = 0
        for url in try fm.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasSuffix(JournalLocations.layoutBackupSuffix) {
            guard let manifest = try? manifest(at: url), manifest.state == .verified, manifest.createdAt < cutoff else { continue }
            try fm.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    /// Every layout backup (any state): Delete All Originals removes them, since each holds originals.
    static func allBackups(in backupsRoot: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil) else { return [] }
        return items.filter {
            $0.lastPathComponent.hasSuffix(JournalLocations.layoutBackupSuffix) || $0.lastPathComponent.hasSuffix(JournalLocations.partialBackupSuffix)
        }
    }

    // MARK: Helpers

    enum MigrationError: Error { case conflict }

    static func stamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func manifest(at backup: URL) throws -> LayoutBackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LayoutBackupManifest.self, from: Data(contentsOf: backup.appending(path: JournalLocations.manifestName)))
    }

    static func write(_ manifest: LayoutBackupManifest, to backup: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileAtomics.write(try encoder.encode(manifest), to: backup.appending(path: JournalLocations.manifestName), mode: .privateToUser)
    }

    /// Regular files under `folder`, as paths relative to it, sorted.
    static func files(under folder: URL) throws -> [LayoutBackupManifest.File] {
        let base = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var out: [LayoutBackupManifest.File] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, url.lastPathComponent != ".DS_Store" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            out.append(.init(path: path, size: Int64(values.fileSize ?? 0)))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Entry folders: `<UUID>` at the top and `.trash/<UUID>`.
    static func entryFolders(under folder: URL) throws -> [(name: String, url: URL)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return [] }
        var out: [(String, URL)] = []
        for name in try fm.contentsOfDirectory(atPath: folder.path) where UUID(uuidString: name) != nil {
            out.append((name, folder.appending(path: name, directoryHint: .isDirectory)))
        }
        let trash = folder.appending(path: SQLiteJournalStore.trashFolderName, directoryHint: .isDirectory)
        if fm.fileExists(atPath: trash.path) {
            for name in try fm.contentsOfDirectory(atPath: trash.path) where UUID(uuidString: name) != nil {
                out.append((name, trash.appending(path: name, directoryHint: .isDirectory)))
            }
        }
        return out
    }

    /// The entry id a manifest path belongs to: `<UUID>/…` or `.trash/<UUID>/…`.
    static func entryID(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        let candidate = parts.first == SQLiteJournalStore.trashFolderName ? parts.dropFirst().first : parts.first
        return candidate.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
    }

    private static func hasFolder(id: String, in images: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: images.appending(path: id).path)
            || fm.fileExists(atPath: images.appending(path: SQLiteJournalStore.trashFolderName).appending(path: id).path)
    }

    static func sameTree(_ a: URL, _ b: URL) throws -> Bool {
        let left = try files(under: a), right = try files(under: b)
        guard left == right else { return false }
        for file in left {
            if try !sameBytes(a.appending(path: file.path), b.appending(path: file.path)) { return false }
        }
        return true
    }

    /// Byte-for-byte comparison, streamed in 1 MB chunks.
    static func sameBytes(_ a: URL, _ b: URL) throws -> Bool {
        let fa = try FileHandle(forReadingFrom: a), fb = try FileHandle(forReadingFrom: b)
        defer { try? fa.close(); try? fb.close() }
        while true {
            let x = try fa.read(upToCount: 1 << 20) ?? Data()
            let y = try fb.read(upToCount: 1 << 20) ?? Data()
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }
}

/// Reads the covered-file records (G-24) of a Journal without opening a store: read-only, no migration, no layout
/// move, nothing written. For the debug report, which may run while the app holds the Journal open.
public enum CoveredFilesReader {
    public static func read(root: URL) throws -> [CoveredFileRecord] {
        let path = root.appendingPathComponent(SQLiteJournalStore.databaseName).path
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let db = try SQLiteConnection(path: path, readOnly: true)
        defer { db.close() }
        guard try db.tableExists("covered_files") else { return [] }
        return try db.query("SELECT id, file_path, bookmark, detector_ids, categories, is_screenshot, covered, caught_at, updated_at, tags_written FROM covered_files ORDER BY caught_at, id",
                            [], SQLiteJournalStore.covered(from:))
    }
}
