import Foundation
import ObscuraSupport

/// What a schema migration's backup holds and how far the migration got (G-26's rule, applied to a schema change that
/// rebuilds a table: G-40's schema 10). Counts and versions only, never a row's content.
struct SchemaBackupManifest: Codable, Equatable {
    enum State: String, Codable { case copied, verified, failed }

    var format = 1
    var createdAt: Date
    var state: State
    /// The schema the copy is at, and the one the migration moves the live file to.
    var fromVersion: Int
    var toVersion: Int
    /// Rows of the table the migration rebuilds, and the entries, in the copy; the migrated file must hold as many.
    var uncheckedRows: Int
    var entriesInDatabase: Int
    var verifiedAt: Date?
    var failure: String?

    enum CodingKeys: String, CodingKey {
        case format, createdAt = "created_at", state, fromVersion = "from_version", toVersion = "to_version",
             uncheckedRows = "unchecked_rows", entriesInDatabase = "entries_in_database", verifiedAt = "verified_at", failure
    }
}

/// G-26 for a schema migration that rebuilds a table (schema 10 rebuilds `unchecked`, G-40): before the migration runs on
/// a Journal that already exists, a consistent copy of the database (`VACUUM INTO`) is written to
/// `Obscura-Backups/<stamp>-before-schema-<n>.noindex/` with its manifest (`copied`), kept out of Time Machine and
/// Spotlight like the layout backup. After the migration commits, the live file is checked against the copy's counts and
/// the manifest marked `verified`; a failed check marks it `failed` and keeps it. Idempotent: a copy already taken for the
/// same step (a launch that stopped before the migration committed) is used again, never a second one. A verified copy
/// goes once the Journal's retention window has passed (`pruneVerified`, from `pruneExpired`, G-26 route C); a failed or
/// unfinished one stays. Without a copy the migration does not run: the file stays at the schema it was, and the store
/// reads and writes it at that schema.
enum SchemaMigrationBackup {
    /// The migrations that rebuild a table holding the person's rows, and so get a copy first.
    static let backedUpVersions: Set<Int> = [10]

    static func suffix(for version: Int) -> String { "-before-schema-\(version).noindex" }
    /// A partial copy older than this was left by a launch that stopped while copying.
    static let partialAge: TimeInterval = 600
    /// A copy being written. Not `.partial.noindex`: the layout migration deletes every folder ending so, and this is not its.
    static func partialSuffix(for version: Int) -> String { "-before-schema-\(version)-partial.noindex" }

    /// Points where a test can make the step fail.
    /// `copying`: before the copy is written (as if it could not be made); `copied`: after it; `migrated`: after the commit.
    enum Step: Equatable, Sendable { case copying, copied, migrated }
    typealias Fault = @Sendable (Step) throws -> Void

    /// The copy for the step `from` → `to`: an existing unfinished one, else a new one. Throws when no copy can be made.
    static func prepare(db: SQLiteConnection, backupsRoot: URL, from: Int, to: Int, now: Date) throws -> URL {
        let fm = FileManager.default
        try JournalPathSafety.checkNotLink(backupsRoot, what: "backups folder")
        try FileAtomics.makePrivateDirectory(backupsRoot)
        try BackupExclusion.exclude(backupsRoot)
        if let existing = try pending(in: backupsRoot, from: from, to: to) {
            Log.journal.info("schema backup reused from=\(from) to=\(to)")
            return existing
        }
        // A partial copy left by a launch that stopped while copying is discarded (the migration never ran after it); one
        // younger than `partialAge` may be another Obscura's copy in progress, so it is left.
        // A folder whose age cannot be read is left too: only one known to be old goes.
        for url in try fm.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasSuffix(partialSuffix(for: to)) {
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > partialAge else { continue }
            try? fm.removeItem(at: url)
        }
        // The stamp says when; the short id keeps two copies taken in the same second apart.
        let stamp = JournalLayoutMigration.stamp(now) + "-" + UUID().uuidString.prefix(8).lowercased()
        let partial = backupsRoot.appending(path: stamp + partialSuffix(for: to), directoryHint: .isDirectory)
        try FileAtomics.makePrivateDirectory(partial)
        try BackupExclusion.exclude(partial)
        let copy = partial.appending(path: SQLiteJournalStore.databaseName)
        try db.exec("VACUUM INTO '\(copy.path.replacingOccurrences(of: "'", with: "''"))'")
        let manifest = SchemaBackupManifest(createdAt: now, state: .copied, fromVersion: from, toVersion: to,
                                            uncheckedRows: try db.scalarInt("SELECT count(*) FROM unchecked"),
                                            entriesInDatabase: try db.scalarInt("SELECT count(*) FROM entries"))
        try write(manifest, to: partial)
        var final = backupsRoot.appending(path: stamp + suffix(for: to), directoryHint: .isDirectory)
        var n = 2
        while fm.fileExists(atPath: final.path) {
            final = backupsRoot.appending(path: "\(stamp)-\(n)" + suffix(for: to), directoryHint: .isDirectory)
            n += 1
        }
        try fm.moveItem(at: partial, to: final)
        Log.journal.info("schema backup written from=\(from) to=\(to) unchecked=\(manifest.uncheckedRows) entries=\(manifest.entriesInDatabase)")
        return final
    }

    /// After the migration committed: the copy is at the schema it was taken at, and the live file holds every row the
    /// copy holds. Marks the manifest `verified`, else `failed` (kept). Returns whether it verified.
    @discardableResult
    static func verify(_ backup: URL, db: SQLiteConnection, now: Date) -> Bool {
        guard var manifest = try? manifest(at: backup) else { return false }
        let unchecked = (try? db.scalarInt("SELECT count(*) FROM unchecked")) ?? -1
        let entries = (try? db.scalarInt("SELECT count(*) FROM entries")) ?? -1
        let copyAt = (try? copyVersion(backup)) ?? -1
        if unchecked == manifest.uncheckedRows && entries == manifest.entriesInDatabase && copyAt == manifest.fromVersion {
            manifest.state = .verified
            manifest.verifiedAt = now
            manifest.failure = nil
            try? write(manifest, to: backup)
            Log.journal.info("schema migration verified to=\(manifest.toVersion) unchecked=\(unchecked) entries=\(entries)")
            return true
        }
        manifest.state = .failed
        manifest.failure = "counts differ"
        try? write(manifest, to: backup)
        Log.journal.error("schema migration verify failed to=\(manifest.toVersion) unchecked=\(unchecked) of \(manifest.uncheckedRows) entries=\(entries) of \(manifest.entriesInDatabase); backup kept")
        return false
    }

    /// The newest unfinished copy for this step, if any.
    static func pending(in backupsRoot: URL, from: Int, to: Int) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupsRoot.path) else { return nil }
        return try fm.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(suffix(for: to)) && !$0.lastPathComponent.hasSuffix(partialSuffix(for: to)) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first { url in
                guard let m = try? manifest(at: url) else { return false }
                return m.state == .copied && m.fromVersion == from && m.toVersion == to
            }
    }

    /// Every schema backup (any state, partial ones included): Delete All Originals removes them with the layout backups.
    static func all(in backupsRoot: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { url in
            let name = url.lastPathComponent
            return backedUpVersions.contains { name.hasSuffix(suffix(for: $0)) || name.hasSuffix(partialSuffix(for: $0)) }
        }
    }

    /// Deletes the verified schema backups taken before `cutoff`; a failed or unfinished one is kept. Returns the count.
    static func pruneVerified(in backupsRoot: URL, takenBefore cutoff: Date) throws -> Int {
        var removed = 0
        for url in all(in: backupsRoot) where !backedUpVersions.contains(where: { url.lastPathComponent.hasSuffix(partialSuffix(for: $0)) }) {
            guard let m = try? manifest(at: url), m.state == .verified, m.createdAt < cutoff else { continue }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    /// The schema the copied database is at.
    static func copyVersion(_ backup: URL) throws -> Int {
        let copy = try SQLiteConnection(path: backup.appending(path: SQLiteJournalStore.databaseName).path, readOnly: true)
        defer { copy.close() }
        return try copy.scalarInt("SELECT coalesce(max(version), 0) FROM schema_version")
    }

    static func manifest(at backup: URL) throws -> SchemaBackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SchemaBackupManifest.self, from: Data(contentsOf: backup.appending(path: JournalLocations.manifestName)))
    }

    static func write(_ manifest: SchemaBackupManifest, to backup: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileAtomics.write(try encoder.encode(manifest), to: backup.appending(path: JournalLocations.manifestName), mode: .privateToUser)
    }
}
