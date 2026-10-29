# ObscuraJournal

roadmap: B-5 · decisions: G-3, G-13, G-23, G-24, G-25, G-26

The Journal keeps every image Obscura cleaned so the user can undo, plus the lists the Settings UI edits (rules, detector overrides, detector state, default style), the daily counters behind "this week" and the "Not checked" list of files Obscura could not check (G-13). Metadata is SQLite; images are files.

## Layout

```
<root>/                          0700   (~/Library/Application Support/Obscura in the app, a temp dir in tests)
├── obscura.sqlite               0600, WAL (+ -wal / -shm, also 0600); backed up (rules with their values sealed per G-30, settings, rects, ids)
└── Journal.noindex/             0700; Spotlight never indexes it; excluded from Time Machine at every launch (G-23)
    ├── <UUID>/                  0700
    │   ├── original.<ext>       0600   ext from container_uti: png / jpg / heic
    │   └── clean.<ext>          0600
    └── .trash/<UUID>/           soft-deleted; purged at init and at every prune
<root>/../Obscura-Backups/       excluded from Time Machine; the layout migration's `<stamp>-before-journal-noindex.noindex/`
```

`JournalLocations` names every folder; nothing else spells a Journal path (a test scans `Sources/`, `Apps/` and `Tools/`
for the old `Journal/` folder). A Journal from before G-23 (`<root>/Journal`) is moved once by `JournalLayoutMigration`
when the store opens: copy the images and a `VACUUM INTO` copy of the database into a `.partial.noindex` folder, write
`manifest.json` (relative paths and sizes only), rename it into place; move the images (one `rename(2)` of the folder, or
entry by entry when the new folder already exists, keeping a byte-identical copy and refusing a differing one); verify
every file against the backup byte for byte and every entry row's folder; mark the manifest `verified`. A stop at any
step leaves the backup and a readable Journal (the store reads an entry from the old folder while it is still there, and
the stale sweep does not delete it); the next launch resumes. A verified backup is deleted by `pruneExpired` once it is
older than the retention window, so it never keeps an original longer than the Journal would (G-26); a failed or
unfinished one is kept; Delete All Originals removes every one. Other folders in `Obscura-Backups` are never touched.

`covered_files` (schema 3, G-24/G-25): one row per covered file on disk, the record behind its Spotlight item and
Finder tags (ObscuraSearch owns the lifetime). It outlives the entry: retention, the sweep and Delete All leave it.

`uncovered_files` (schema 5, fail-open #7): one row per file on disk that should hold a covered picture Obscura could not
write there (the caught file, or its "(clean)" copy), with the caught file, the entry and the attempts. It stays until a
write there succeeds, a later check of the caught file reaches a verdict, the catch is undone on purpose, or the user
dismisses it; retention, the sweep and Delete All leave it (the secret is in the file, not in the Journal).

Schema (version 10): `Migrations/001_initial.sql`, `002_unchecked.sql` and `003_covered_files.sql` are the DDL from ARCHITECTURE.md §5, verbatim; `004_unchecked_reasons.sql` widens the Not checked reasons; `005_uncovered_files.sql` adds the not-covered list; `006_clean_digest.sql` adds the clean picture's digest; `007_drop_text_hash.sql` removes the secret hashes; `008_seal_rule_values.sql` replaces `rules.value` with `sealed_value` (G-30; the store seals each row in Swift between its two halves, `sealRuleValues008` and `sealRuleValues008Finish`); `009_seal_detector_overrides.sql` replaces `detector_overrides.specs_json` with `sealed_specs` (scan F15/F24; same two-halves pattern); `010_unread_spots.sql` (G-40) rebuilds `unchecked` with the `unreadPatch` and `textNotRead` reasons and `settled_at` (a spot row whose every spot is settled is kept as the record, not listed), and adds `unread_spots` (each spot's rect, its padded cover, its state `pending`/`notText`/`covered`/`tooSmall`, and the entry and finding that cover it); before it runs on an existing Journal a copy of the database is written to `Obscura-Backups/<stamp>-before-schema-10.noindex/` (`SchemaMigrationBackup`, G-26: verified after the commit, reused if a launch stopped, pruned after the retention window; without a copy the migration waits); `Migrations.swift` embeds each as a string (a test proves each pair identical, and that there is one file per listed migration). Migration 2 is tested forward from a schema-1 Journal with entries, findings, rules and stats in it. Migrations run in a transaction and append a `schema_version` row. A file whose version is higher than the code knows is refused with `JournalError.newerSchema(found:supported:)`. The two PRAGMA lines are connection settings set by `SQLiteConnection` and are skipped inside the migration transaction.

## Invariants

- Text is never stored, nor a hash of it. Findings carry rects, detector ids and a category; the original image is the only copy of the secret and retention removes it. Schema 7 (fail-open #19, G-29) dropped `findings.text_hash` (an unsalted SHA-256 of each secret, which nothing read): the table is rebuilt and the store zeroes the freed pages (`secure_delete`), VACUUMs and truncates the WAL, so no copy of a hash stays in the file. Logs carry counts only.
- Custom rule values are sealed at rest (schema 8, G-30). `rules.sealed_value` is `RuleSeal` format 1: a version byte,
  an 8-byte key id (HMAC-SHA-256 of a constant under the key), then AES-256-GCM nonce + ciphertext + tag, with the rule's
  id, action and kind as authenticated data (a value moved to another row, or an action flipped behind the store, does
  not open). Keys come from a `RuleKeyStore` the caller passes (no default): `KeychainRuleKeyStore` (one login-keychain
  item per key, account `rule-value-key.v2.<key id hex>`, ThisDeviceOnly, not synchronizable) in the app and for the
  CLI's `--root`, `InMemoryRuleKeyStore` for temporary Journals and tests. F21 (G-34): a store seals only with a key it
  generated itself (stored under its id; an item already there is never adopted); its first write re-seals every value
  it can open under that key and retires keys no value names; a key read back opens a value only when its bytes give the
  id the value names. Keys are asked for only when a rule is read or written, cached, never logged or written anywhere
  else. `rules()` returns `StoredRule`: `.readable(RuleRecord)` or `.unreadable(UnreadableRule)` with
  the reason (`keyMissing`, `otherKey`, `damaged`, `unknownFormat`, `keyUnavailable`); an unreadable rule is listed,
  never dropped, never read as anything else. Migration 8 seals every plain value with the key and scrubs the file
  (secure_delete, VACUUM, WAL truncate) like schema 7; when the key store does not answer and there are values to seal,
  the store still opens at schema 7, reports every rule as `keyUnavailable` (never using the plain value) and seals at
  the next read or write once it answers.
- Detector-override pattern lists are sealed the same way (schema 9, scan F15/F24): `detector_overrides.sealed_specs`
  in `RuleSeal` format 1 with "obscura.detector-overrides.specs.v1" and the detector id as authenticated data
  (`OverrideSeal`), the same keys (G-34), the same scrub and the same wait when the key store does not answer.
  `overrides()` returns the lists that open; `unreadableOverrides()` the rest with the reason. An unreadable list is never
  compiled: `CatalogueBuilder` raises `problem.override.undecodable` for it and the detector runs on its built-in
  patterns. Export stays plain (the person's act); an import restores an unreadable list.
- Every write is atomic: files through `FileAtomics` (temp + rename, then 0600), rows through one SQLite transaction. `create` writes files first, then rows, and removes the folder if the rows fail. Trash/restore move the folder, then update `trashed_at`, and move it back if the update fails.
- The clean picture always matches the covered flags (G-28, fail-open #4): `commitRender` is the only way an entry's
  picture, flags or style change; the engine renders first and commits picture + flags + style + revision together,
  only at the revision it started from (`revisionConflict` otherwise). Each row carries `clean_sha256` (schema 6) of the
  clean file it was committed with; `cleanData`, `cleanURL` and `cleanImage` (entry + bytes in one actor turn) refuse a
  file that does not match (`cleanOutOfDate`), and `entriesNeedingRender` lists them for the engine to render again
  (every entry from before schema 6 starts there).
- One connection, owned by the `SQLiteJournalStore` actor. `SQLiteConnection` is a thin wrapper over the system `SQLite3` module (open, exec, prepare/bind/step, typed row accessors, transactions, WAL, foreign keys on, 5 s busy timeout). No ORM, no dependency.
- Time comes from `WallClock` (ObscuraSupport): `created_at`, `trashed_at`, stats days and the prune cutoff all use it, so tests drive retention with `ManualClock`.
- Dates are ISO-8601 UTC with fractional seconds, rounded to the millisecond before formatting (the format truncates, so an unrounded round trip lost 1 ms), so string comparison in SQL is chronological and a row read back and written again is unchanged. Stats days are `YYYY-MM-DD` in `Calendar.current`.
- Retention (`pruneExpired`) deletes whole entries, folder and rows; it purges the trash first. `sweepStale` deletes entries whose original or clean file is missing; `sweepOrphans` removes entry-id folders (live or trash) no row names. `deleteAll` empties the `Journal.noindex/` folder and the rows. Every delete removes the folder before the row (fail-open #11), so a crash or a folder that will not go leaves the row (still listed, swept, tried again) and never an original nothing points at; each of these goes on past a failure and throws `maintenanceIncomplete(step:failed:)` at the end, which the engine shows as a problem until a later tick finishes. The trash purge at launch never stops the store from opening.
- `unchecked` (G-13) keeps one row per file path that was left without a verdict: origin (`watched` carries its folder), reason (only the engine's retryable outcomes, enforced by a CHECK), first and last sighting, attempts. No image copy, no text. `recordUnchecked` upserts (one more attempt), `clearUnchecked(path:)` follows a later verdict, `dismissUnchecked` / `restoreUnchecked` are Dismiss and its undo. Retention, the stale sweep and `deleteAll` leave it alone: a file still to check is not a catch.
- Stats rows older than 90 days are pruned on every `record`. `weekStats()` is `stats(days: 7)`: today and the six days before, oldest first, zero-filled.
- Styles: one row has `is_default = 1`; entries created without a style point at it, so `setDefaultStyle` changes them too. `setStyle(entryID:)` inserts a private row; orphaned private rows are removed when their entry goes.
- Every failure is a `JournalError`; nothing is swallowed.

## Import / export

`exportRules()` writes one JSON document (`RulesDocument`, `format_version` 1): rules, detector overrides (`specs_json` kept as the stored string), detector state and the default style. `importRules(_:conflicts:)` merges by id inside one transaction; identical items are reported unchanged, new ones added, differing ones listed in `ImportReport.conflicts` with both versions. The default policy `.preferIncoming` stores the imported value; `.keepExisting` only reports. A rules file is untrusted (security scan 2026-10-28 F16/F22): `RulesImportValidation` checks every item first. Rule ids must be `custom.<UUID>` and are stored in one canonical spelling; override and detector-state ids must have a built-in id's ASCII shape; values, names and token lengths have bounds; a repeated id keeps its first item. Every refused item is listed in `ImportReport.rejected` (id and reason, never a value). Rule orders are clamped into `RuleOrder.range`, and the next order is `RuleOrder.next(after:)`, which cannot overflow. Ids read back from the store are merged by Swift equality, never trapped on.

G-30: the export holds each readable rule's value in plain text. It is the person's explicit act, to a file they choose (the save panel says the file is not encrypted), and it is how rules move to another Mac, which cannot open this Mac's sealed values. Unreadable rules are left out of it. An import restores a rule stored here as unreadable from the file's value whatever the policy (`ImportReport.rulesRecovered`): there is nothing readable to keep.

## Reading it without the app

```
sqlite3 ~/Library/Application\ Support/Obscura/obscura.sqlite 'SELECT id, created_at, display_name, revision FROM entries ORDER BY created_at DESC'
```
