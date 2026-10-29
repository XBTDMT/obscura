public import Foundation

/// The Journal: originals and clean copies as files, everything else in SQLite. See README.md for the invariants.
/// Implementations are actors; one connection, every write atomic, no recognized text ever stored.
public protocol JournalStore: Actor {
    // Entries
    func create(_ entry: NewEntry, original: Data, clean: Data) async throws -> Entry
    func entry(_ id: UUID) async throws -> Entry
    func entries(matching query: EntryQuery) async throws -> [Entry]
    /// The only way an entry's picture, covered flags or style change (G-28, fail-open #4): `clean` is the picture already
    /// rendered for exactly the findings in `enabled` (every other finding of the entry is left visible) and `style`
    /// (nil keeps the entry's own). The clean file, the flags, the style, the digest and the revision change together,
    /// and only while the entry is still at `expectedRevision` (else `revisionConflict`: render again from the new
    /// state). On any failure the entry is left as it was: rows untouched, the previous clean file put back.
    /// Returns the committed entry.
    @discardableResult
    func commitRender(_ entryID: UUID, clean: Data, enabled: Set<UUID>, style: StyleRecord?, expectedRevision: Int) async throws -> Entry
    /// G-40 "Cover it": adds findings to an entry LEFT VISIBLE (the picture does not change, so no flag claims a cover
    /// the clean picture lacks, G-28) and bumps its revision; `commitRender` then covers them. Only while the entry is at
    /// `expectedRevision` (else `revisionConflict`). Returns the entry.
    func addVisibleFindings(_ entryID: UUID, _ findings: [NewFinding], expectedRevision: Int) async throws -> Entry
    /// The entry and its clean picture from one moment (G-28). Throws `cleanOutOfDate` when the bytes do not match the
    /// digest the row was committed with: a picture whose flags it might not match is never handed out.
    func cleanImage(_ entryID: UUID) async throws -> CleanImage
    /// Live entries whose clean picture is not trusted (no digest yet, or the file does not match it): the engine renders
    /// each again from its original and its flags.
    func entriesNeedingRender() async throws -> [UUID]
    func trash(_ ids: [UUID]) async throws
    func restore(_ ids: [UUID]) async throws
    func purgeTrash() async throws
    /// Deletes live entries created more than `olderThan` ago (folder + rows) and purges the trash. Returns the count.
    func pruneExpired(olderThan: Duration) async throws -> Int
    /// Deletes live entries whose original or clean file is missing. Returns the count.
    func sweepStale() async throws -> Int
    /// Removes entry folders no row names (an original nothing lists, left by a crash). Returns the count. Like the prune
    /// and the sweep, it goes on past a failure and throws `maintenanceIncomplete` at the end.
    func sweepOrphans() async throws -> Int
    func deleteAll() async throws
    func originalData(_ entryID: UUID) async throws -> Data
    /// The clean picture, verified against its row's digest (`cleanOutOfDate` otherwise). A caller that also needs the
    /// flags uses `cleanImage(_:)`.
    func cleanData(_ entryID: UUID) async throws -> Data
    func originalURL(_ entryID: UUID) async throws -> URL
    /// The clean file, handed out only while it matches its row's digest (`cleanOutOfDate` otherwise).
    func cleanURL(_ entryID: UUID) async throws -> URL

    // Stats
    func record(stat: StatEvent) async throws
    /// Today and the six days before it, oldest first, zero-filled, local calendar.
    func weekStats() async throws -> [DayStats]
    func stats(days: Int) async throws -> [DayStats]

    // Rules. Each value is sealed at rest with a per-install key (G-30); these calls open and seal it.
    /// Every rule in order, each readable or unreadable on this Mac (its value would not open: no key, another key,
    /// damaged, or the key store did not answer). An unreadable rule is listed, never dropped and never compiled.
    func rules() async throws -> [StoredRule]
    /// Seals the value and stores the rule (replacing any row with its id, an unreadable one included). Throws
    /// `ruleKeyUnavailable` and writes nothing when the key store cannot be asked.
    func upsertRule(_ rule: RuleRecord) async throws
    func deleteRule(_ id: String) async throws
    /// Sets sort_order to each id's position; ids not listed keep their relative order after the listed ones.
    func reorderRules(_ ids: [String]) async throws

    // Detector overrides and state
    /// The edited detectors whose sealed pattern list opens on this Mac (F15). An unreadable one is never left out
    /// silently: it is in `unreadableOverrides()`, and its detector runs on its built-in patterns.
    func overrides() async throws -> [OverrideRecord]
    func unreadableOverrides() async throws -> [UnreadableOverride]
    func setOverride(_ detectorID: String, specsJSON: String) async throws
    func clearOverride(_ detectorID: String) async throws
    func detectorState() async throws -> [String: Bool]
    func setDetectorEnabled(_ detectorID: String, enabled: Bool) async throws

    // Styles
    func defaultStyle() async throws -> StyleRecord
    func setDefaultStyle(_ style: StyleRecord) async throws

    // Not checked (G-13): files left without a verdict, kept until a later check reaches one or the user dismisses them.
    /// Records that the file at `path` was left without a verdict: a new row, or, for a path already listed, the new
    /// origin and reason, `lastSeen` = now and one more attempt (`firstSeen` and the id stay). Returns the row.
    func recordUnchecked(path: String, origin: UncheckedOrigin, reason: UncheckedReason) async throws -> UncheckedRecord
    /// A later check of `path` reached a verdict: its row goes. Nothing happens when the path is not listed.
    func clearUnchecked(path: String) async throws
    /// The user dismissed the row. Throws `uncheckedNotFound` when there is none with this id.
    func dismissUnchecked(_ id: UUID) async throws
    /// Puts a row back exactly as it was (the undo of a dismiss), replacing any row for the same path.
    func restoreUnchecked(_ record: UncheckedRecord) async throws
    /// Every listed file, most recently seen first (a settled spot row, G-40, is not listed).
    func uncheckedFiles() async throws -> [UncheckedRecord]

    // Unread spots (G-40, schema 10): a picture whose only unread parts are small spots no reading could read.
    /// As `recordUnchecked(path:origin:reason:)`, with the spots of an `unreadPatch` row (replacing any it had). The row is
    /// settled (kept as the record, not listed) when it has spots and none is pending.
    func recordUnchecked(path: String, origin: UncheckedOrigin, reason: UncheckedReason, spots: [SpotRecord]) async throws -> UncheckedRecord
    /// The spot rows whose every spot is settled, most recently settled first.
    func settledSpotFiles() async throws -> [UncheckedRecord]
    /// One row by id, listed or settled. Throws `uncheckedNotFound` when there is none.
    func uncheckedFile(_ id: UUID) async throws -> UncheckedRecord
    /// The spot rows with a spot in this entry.
    func spotFiles(entryID: UUID) async throws -> [UncheckedRecord]
    /// Sets each spot's state, entry and cover finding (same number and order as the row's spots); the row is settled
    /// when none is pending and listed again when one is. Returns the row.
    func updateSpots(_ id: UUID, spots: [SpotRecord]) async throws -> UncheckedRecord

    // Not covered on disk (fail-open #7): files that still show what Obscura caught because the covered picture could
    // not be written there. Kept until a write there succeeds, the caught file gets a verdict, the catch is undone or
    // the row is dismissed; retention, the stale sweep and Delete All leave them (the secret is in the file, not here).
    /// Records that the covered picture could not be written to `path` (the caught file `sourcePath`, or its clean copy):
    /// a new row, or, for a path already listed, the new source and entry, `lastSeen` = now and one more attempt.
    func recordUncovered(path: String, sourcePath: String, entryID: UUID?) async throws -> UncoveredRecord
    /// A write to `path` succeeded, or a later check of the caught file `path` reached a verdict: every row whose file or
    /// caught file is `path` goes. Returns the rows removed.
    @discardableResult func clearUncovered(path: String) async throws -> [UncoveredRecord]
    /// The catch was undone on purpose: its file shows the original because the user asked. Returns the rows removed.
    @discardableResult func clearUncovered(entryID: UUID) async throws -> [UncoveredRecord]
    /// The user dismissed the row. Throws `uncoveredNotFound` when there is none with this id.
    func dismissUncovered(_ id: UUID) async throws
    /// Puts a row back exactly as it was (the undo of a dismiss), replacing any row for the same path.
    func restoreUncovered(_ record: UncoveredRecord) async throws
    /// Every listed file, most recently seen first.
    func uncoveredFiles() async throws -> [UncoveredRecord]

    // Covered files (G-24): the files on disk Obscura covered, behind the Spotlight items and Finder tags.
    /// Every record, oldest catch first.
    func coveredFiles() async throws -> [CoveredFileRecord]
    func coveredFile(_ id: UUID) async throws -> CoveredFileRecord?
    /// Stores the record by id. A record for the same path under another id (the file was caught again) is removed
    /// first; its id is returned so its Spotlight item can go too.
    @discardableResult func upsertCoveredFile(_ record: CoveredFileRecord) async throws -> [UUID]
    /// Removes the record; nothing happens when there is none.
    func deleteCoveredFile(_ id: UUID) async throws

    // Import / export
    /// A rules document with every readable rule's value in plain text, for a file the user saves (G-30: it is how rules
    /// move between Macs). Unreadable rules are left out.
    func exportRules() async throws -> Data
    /// Imports a document; a rule stored here whose value is unreadable is restored from the file whatever `policy`
    /// says (`rulesRecovered`).
    func importRules(_ data: Data, conflicts policy: ImportConflictPolicy) async throws -> ImportReport
}

public extension JournalStore {
    func importRules(_ data: Data) async throws -> ImportReport { try await importRules(data, conflicts: .preferIncoming) }
}
