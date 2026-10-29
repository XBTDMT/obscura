// Generated from Migrations/NNN_*.sql — keep each string identical to its file (a test compares them).
// Migrations are applied by `Migrations.apply`; PRAGMA lines are connection settings and are skipped inside the transaction.

enum Migrations {
    static let all: [(version: Int, sql: String)] = [
        (1, initial001),
        (2, unchecked002),
        (3, coveredFiles003),
        (4, uncheckedReasons004),
        (5, uncoveredFiles005),
        (6, cleanDigest006),
        (7, dropTextHash007),
        (8, sealRuleValues008),
        (9, sealDetectorOverrides009),
        (10, unreadSpots010),
    ]

    static var latestVersion: Int { all.last?.version ?? 0 }

    static let initial001 = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE schema_version (
  version     INTEGER NOT NULL,
  applied_at  TEXT    NOT NULL            -- ISO-8601 UTC
);

CREATE TABLE entries (
  id             TEXT PRIMARY KEY,        -- UUID string, also the folder name
  created_at     TEXT NOT NULL,           -- ISO-8601 UTC
  source         TEXT NOT NULL CHECK (source IN ('file','clipboard','imported','demo')),
  display_name   TEXT NOT NULL,
  file_path      TEXT,                    -- original user file (replace mode) or nil for clipboard
  clean_copy_path TEXT,                   -- keepBoth sibling, if any
  container_uti  TEXT NOT NULL,           -- public.png, public.jpeg, public.heic
  pixel_width    INTEGER NOT NULL,
  pixel_height   INTEGER NOT NULL,
  revision       INTEGER NOT NULL DEFAULT 1,   -- bumped on every clean re-render
  style_id       INTEGER NOT NULL REFERENCES styles(id),
  trashed_at     TEXT                     -- non-null while in .trash
);
CREATE INDEX entries_created_at ON entries(created_at);
CREATE INDEX entries_trashed_at ON entries(trashed_at);

CREATE TABLE findings (
  id            TEXT PRIMARY KEY,         -- UUID
  entry_id      TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  line_index    INTEGER NOT NULL,
  rect_x        REAL NOT NULL, rect_y REAL NOT NULL, rect_w REAL NOT NULL, rect_h REAL NOT NULL,  -- image pixels, top-left origin
  detector_ids  TEXT NOT NULL,            -- JSON array; first = display label
  category      TEXT NOT NULL,
  text_hash     TEXT,                     -- SHA-256 of the matched text; the text itself is never stored
  enabled       INTEGER NOT NULL DEFAULT 1   -- 0 = user left it visible (per-finding undo)
);
CREATE INDEX findings_entry ON findings(entry_id);

CREATE TABLE styles (
  id         INTEGER PRIMARY KEY,
  kind       TEXT NOT NULL CHECK (kind IN ('solid','erase','blur','mosaic')),
  color_rgba TEXT NOT NULL,               -- "r,g,b,a" 0..1
  roundness  REAL NOT NULL,               -- 0..1
  padding    REAL NOT NULL,               -- fraction of text height
  label_mode TEXT NOT NULL CHECK (label_mode IN ('none','redacted','kind')),
  is_default INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE rules (                      -- user custom rules and allow rules
  id          TEXT PRIMARY KEY,           -- "custom.<UUID>"
  action      TEXT NOT NULL CHECK (action IN ('blackOut','allow')),
  kind        TEXT NOT NULL CHECK (kind IN ('exactText','prefix','label','example','regex')),
  value       TEXT NOT NULL,              -- what the user typed
  token_length INTEGER,                   -- prefix kind
  name        TEXT,
  enabled     INTEGER NOT NULL DEFAULT 1,
  created_at  TEXT NOT NULL,
  sort_order  INTEGER NOT NULL
);

CREATE TABLE detector_overrides (         -- replaces a built-in detector's whole pattern list
  detector_id TEXT PRIMARY KEY,
  specs_json  TEXT NOT NULL,              -- JSON array of PatternSpec
  updated_at  TEXT NOT NULL
);

CREATE TABLE detector_state (             -- per-detector on/off (built-ins)
  detector_id TEXT PRIMARY KEY,
  enabled     INTEGER NOT NULL
);

CREATE TABLE stats_days (
  day        TEXT PRIMARY KEY,            -- local-date "YYYY-MM-DD"
  checked    INTEGER NOT NULL DEFAULT 0,
  caught     INTEGER NOT NULL DEFAULT 0,  -- images with ≥1 finding
  secrets    INTEGER NOT NULL DEFAULT 0,
  skipped_json TEXT NOT NULL DEFAULT '{}',   -- {"ocrTimeout": n, ...}
  categories_json TEXT NOT NULL DEFAULT '{}' -- {"ai": n, ...}
);
"""

    static let unchecked002 = """
-- Files Obscura could not check (G-13): a path, where it came from, why, and when. Never an image copy (the file
-- was never read to the end) and never recognized text. A row leaves when a later check of the path reaches a
-- verdict or the user dismisses it.
CREATE TABLE unchecked (
  id             TEXT PRIMARY KEY,        -- UUID
  file_path      TEXT NOT NULL UNIQUE,    -- the file's resolved path, one row per file
  origin         TEXT NOT NULL CHECK (origin IN ('screenshotFolder','downloads','watched','imported')),
  watched_folder TEXT,                    -- the extra folder, for origin 'watched' only
  reason         TEXT NOT NULL CHECK (reason IN ('ocrTimeout','ocrFailed','queueFull','renderFailed','encodeFailed','journalFailed','catalogueFailed')),
  first_seen     TEXT NOT NULL,           -- ISO-8601 UTC
  last_seen      TEXT NOT NULL,           -- ISO-8601 UTC
  attempts       INTEGER NOT NULL DEFAULT 1 CHECK (attempts >= 1),
  CHECK ((origin = 'watched') = (watched_folder IS NOT NULL))
);
CREATE INDEX unchecked_last_seen ON unchecked(last_seen);
"""

    static let coveredFiles003 = """
-- Covered files Obscura labels for search (G-24): one row per file on disk that Obscura covered, so its Spotlight item
-- and Finder tags live as long as the file, not as long as the Journal entry (24 h by default). Labels only: detector
-- ids and categories, never recognized text, a hash of it or anything derived from a value.
CREATE TABLE covered_files (
  id            TEXT PRIMARY KEY,         -- UUID of the Journal entry the file was caught as; the Spotlight item id
  file_path     TEXT NOT NULL UNIQUE,     -- the covered file's path, as last found
  bookmark      BLOB,                     -- a bookmark of the file, so a move or rename is followed
  detector_ids  TEXT NOT NULL,            -- JSON array: the detectors of the findings covered now
  categories    TEXT NOT NULL,            -- JSON array: their categories
  is_screenshot INTEGER NOT NULL DEFAULT 0,
  covered       INTEGER NOT NULL DEFAULT 1,  -- 0 while Undo shows the original: no item, no tags, kept for Redo
  caught_at     TEXT NOT NULL,            -- ISO-8601 UTC
  updated_at    TEXT NOT NULL,            -- ISO-8601 UTC
  tags_written  TEXT NOT NULL DEFAULT '[]'  -- JSON array: the Finder tags Obscura added (never the user's own)
);
"""

    static let uncheckedReasons004 = """
-- More reasons a file can be left without a verdict (fail-open review 2026-10-27): a picture that could not be opened
-- (decodeFailed, unsupportedImage, unreadable, tooLarge), one still being written (incomplete), one with several frames
-- that could not be covered (multiFrame), and one that arrived while protection was paused (protectionPaused).
-- SQLite cannot change a CHECK constraint in place, so the table is rebuilt with the wider list and every existing row
-- is copied as it is (ids, paths, origins, reasons, sightings and attempt counts unchanged).
CREATE TABLE unchecked_v4 (
  id             TEXT PRIMARY KEY,        -- UUID
  file_path      TEXT NOT NULL UNIQUE,    -- the file's resolved path, one row per file
  origin         TEXT NOT NULL CHECK (origin IN ('screenshotFolder','downloads','watched','imported')),
  watched_folder TEXT,                    -- the extra folder, for origin 'watched' only
  reason         TEXT NOT NULL CHECK (reason IN ('ocrTimeout','ocrFailed','queueFull','renderFailed','encodeFailed','journalFailed','catalogueFailed',
                                                 'decodeFailed','unsupportedImage','unreadable','tooLarge','incomplete',
                                                 'multiFrame','protectionPaused')),
  first_seen     TEXT NOT NULL,           -- ISO-8601 UTC
  last_seen      TEXT NOT NULL,           -- ISO-8601 UTC
  attempts       INTEGER NOT NULL DEFAULT 1 CHECK (attempts >= 1),
  CHECK ((origin = 'watched') = (watched_folder IS NOT NULL))
);
INSERT INTO unchecked_v4 (id, file_path, origin, watched_folder, reason, first_seen, last_seen, attempts)
  SELECT id, file_path, origin, watched_folder, reason, first_seen, last_seen, attempts FROM unchecked;
DROP TABLE unchecked;
ALTER TABLE unchecked_v4 RENAME TO unchecked;
CREATE INDEX unchecked_last_seen ON unchecked(last_seen);
"""

    static let uncoveredFiles005 = """
-- Files on disk that still show what Obscura caught (fail-open #7): a catch whose covered picture could not be written
-- to the file (or to its "(clean)" copy), and a Black Out Again or finding change whose write did not land. One row per
-- file that should hold the covered picture; it stays until a write there succeeds, a later check of the caught file
-- reaches a verdict, the catch is undone on purpose, or the user dismisses it. It outlives the Journal entry (retention
-- removes the entry, not the secret in the file), so it has no foreign key. Paths only: no image, no recognized text.
CREATE TABLE uncovered_files (
  id          TEXT PRIMARY KEY,           -- UUID
  file_path   TEXT NOT NULL UNIQUE,       -- where the covered picture belongs: the caught file, or its "(clean)" copy
  source_path TEXT NOT NULL,              -- the caught file itself (the same path unless the clean copy is kept beside it)
  entry_id    TEXT,                       -- the Journal entry whose covered picture belongs there; may outlive the entry
  first_seen  TEXT NOT NULL,              -- ISO-8601 UTC
  last_seen   TEXT NOT NULL,              -- ISO-8601 UTC
  attempts    INTEGER NOT NULL DEFAULT 1 CHECK (attempts >= 1)
);
CREATE INDEX uncovered_files_source ON uncovered_files(source_path);
CREATE INDEX uncovered_files_entry ON uncovered_files(entry_id);
"""

    static let cleanDigest006 = """
-- The clean picture always matches the covered flags (fail-open #4, G-28): each entry row carries the SHA-256 of the
-- clean file it was committed with, written in the same transaction as the flags, the style and the revision. A read
-- whose bytes do not match (a crash between the file and the row, a file changed behind the store) or a row without a
-- digest (every entry from before this migration) is refused, and the engine renders that entry's clean picture again
-- from its original and its flags. The digest is of a whole image file, never of recognized text.
ALTER TABLE entries ADD COLUMN clean_sha256 TEXT;
"""

    static let dropTextHash007 = """
-- No hash of a secret is kept (fail-open #19, G-29): `findings.text_hash` held an unsalted SHA-256 of each matched
-- secret, which nothing reads, and which a low-entropy kind (a card number, a phone number, an IBAN, an email) can be
-- brute-forced back from. The table is rebuilt without the column and every other value is copied as it is. The store
-- runs this with secure_delete on and then VACUUMs and truncates the WAL, so the freed pages that held the hashes are
-- overwritten, not just unlinked.
CREATE TABLE findings_v7 (
  id            TEXT PRIMARY KEY,         -- UUID
  entry_id      TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  line_index    INTEGER NOT NULL,
  rect_x        REAL NOT NULL, rect_y REAL NOT NULL, rect_w REAL NOT NULL, rect_h REAL NOT NULL,  -- image pixels, top-left origin
  detector_ids  TEXT NOT NULL,            -- JSON array; first = display label
  category      TEXT NOT NULL,
  enabled       INTEGER NOT NULL DEFAULT 1   -- 0 = user left it visible (per-finding undo)
);
INSERT INTO findings_v7 (id, entry_id, line_index, rect_x, rect_y, rect_w, rect_h, detector_ids, category, enabled)
  SELECT id, entry_id, line_index, rect_x, rect_y, rect_w, rect_h, detector_ids, category, enabled FROM findings;
DROP TABLE findings;
ALTER TABLE findings_v7 RENAME TO findings;
CREATE INDEX findings_entry ON findings(entry_id);
"""

    /// The first half of `008_seal_rule_values.sql`: the new table. The store then seals every row into it (SQL cannot
    /// encrypt) and runs `sealRuleValues008Finish`, all in one transaction.
    static let sealRuleValues008 = """
-- Custom rule values are sealed at rest (G-30): `rules.value` held what the person typed in plain text, and an exact-text
-- rule can be the secret itself; obscura.sqlite is backed up on purpose (G-23). The table is rebuilt with
-- `sealed_value` (format version, key id, AES-GCM nonce, ciphertext and tag; see RuleSeal.swift) in place of `value`.
-- SQL cannot encrypt, so between the two halves of this file the store seals each row of `rules` into `rules_v8` in the
-- same transaction, with the per-install key from the Keychain; every other column is copied as it is. The store runs
-- this with secure_delete on and then VACUUMs and truncates the WAL, so no plain value is left in freed pages or the log.
CREATE TABLE rules_v8 (                   -- user custom rules and allow rules
  id           TEXT PRIMARY KEY,          -- "custom.<UUID>"
  action       TEXT NOT NULL CHECK (action IN ('blackOut','allow')),
  kind         TEXT NOT NULL CHECK (kind IN ('exactText','prefix','label','example','regex')),
  sealed_value BLOB NOT NULL CHECK (typeof(sealed_value) = 'blob'),  -- what the user typed, sealed (G-30); never plain
  token_length INTEGER,                   -- prefix kind
  name         TEXT,
  enabled      INTEGER NOT NULL DEFAULT 1,
  created_at   TEXT NOT NULL,
  sort_order   INTEGER NOT NULL
);
"""

    /// The second half of `008_seal_rule_values.sql`, run after every row is sealed into `rules_v8`.
    static let sealRuleValues008Finish = """
DROP TABLE rules;
ALTER TABLE rules_v8 RENAME TO rules;
"""

    /// The first half of `009_seal_detector_overrides.sql`: the new table. The store then seals every row into it and runs
    /// `sealDetectorOverrides009Finish`, all in one transaction (scan F15/F24).
    static let sealDetectorOverrides009 = """
-- Detector-override patterns are sealed at rest (scan F15/F24, with G-30's key and format): `detector_overrides.specs_json`
-- held each edited detector's pattern list in plain text, and an "Exact text" or "Looks like this" pattern can be the
-- secret itself; obscura.sqlite is backed up on purpose (G-23). The table is rebuilt with `sealed_specs` (RuleSeal format
-- 1; authenticated data "obscura.detector-overrides.specs.v1" and the detector id) in place of `specs_json`. Between the
-- two halves of this file the store seals each row into `detector_overrides_v9` in the same transaction; it runs with
-- secure_delete on and then VACUUMs and truncates the WAL, so no plain pattern is left in freed pages or the log.
CREATE TABLE detector_overrides_v9 (      -- replaces a built-in detector's whole pattern list
  detector_id  TEXT PRIMARY KEY,
  sealed_specs BLOB NOT NULL CHECK (typeof(sealed_specs) = 'blob'),  -- JSON array of PatternSpec, sealed; never plain
  updated_at   TEXT NOT NULL
);
"""

    /// The second half of `009_seal_detector_overrides.sql`, run after every row is sealed into `detector_overrides_v9`.
    static let sealDetectorOverrides009Finish = """
DROP TABLE detector_overrides;
ALTER TABLE detector_overrides_v9 RENAME TO detector_overrides;
"""

    static let unreadSpots010 = """
-- G-40: a picture whose only unread parts are small spots that look like text to Vision's rectangle detector but that no
-- reading can read. Such a file is listed under Not checked with its own reason (`unreadPatch`, not `ocrFailed`: Vision
-- answered every call, with no text), and each spot's rect is kept with the row so the viewer can outline it and the
-- person can settle it (Not text, or Cover it). With the opt-in switches a spot can also be covered when it is found
-- (B) or skipped as too small to hold a secret (D); either way the record stays, so nothing is settled silently.
-- Also a truer reason for a picture part of which Vision answered with no text outside that case (`textNotRead`): it
-- was not a failure either, so it is no longer stored as `ocrFailed`.
-- SQLite cannot change a CHECK constraint in place, so `unchecked` is rebuilt with the wider list and a `settled_at`
-- column (NULL: listed under Not checked; set: every spot of the row is settled, the row is kept as the record), and
-- every existing row is copied as it is (ids, paths, origins, reasons, sightings and attempt counts unchanged).
CREATE TABLE unchecked_v10 (
  id             TEXT PRIMARY KEY,        -- UUID
  file_path      TEXT NOT NULL UNIQUE,    -- the file's resolved path, one row per file
  origin         TEXT NOT NULL CHECK (origin IN ('screenshotFolder','downloads','watched','imported')),
  watched_folder TEXT,                    -- the extra folder, for origin 'watched' only
  reason         TEXT NOT NULL CHECK (reason IN ('ocrTimeout','ocrFailed','queueFull','renderFailed','encodeFailed','journalFailed','catalogueFailed',
                                                 'decodeFailed','unsupportedImage','unreadable','tooLarge','incomplete',
                                                 'multiFrame','protectionPaused','unreadPatch','textNotRead')),
  first_seen     TEXT NOT NULL,           -- ISO-8601 UTC
  last_seen      TEXT NOT NULL,           -- ISO-8601 UTC
  attempts       INTEGER NOT NULL DEFAULT 1 CHECK (attempts >= 1),
  settled_at     TEXT,                    -- ISO-8601 UTC; non-null only for 'unreadPatch' rows whose every spot is settled
  CHECK ((origin = 'watched') = (watched_folder IS NOT NULL)),
  CHECK (settled_at IS NULL OR reason = 'unreadPatch')
);
INSERT INTO unchecked_v10 (id, file_path, origin, watched_folder, reason, first_seen, last_seen, attempts, settled_at)
  SELECT id, file_path, origin, watched_folder, reason, first_seen, last_seen, attempts, NULL FROM unchecked;
DROP TABLE unchecked;
ALTER TABLE unchecked_v10 RENAME TO unchecked;
CREATE INDEX unchecked_last_seen ON unchecked(last_seen);

CREATE TABLE unread_spots (               -- the spots of an 'unreadPatch' row, in the order the engine found them
  unchecked_id TEXT NOT NULL REFERENCES unchecked(id) ON DELETE CASCADE,
  ordinal      INTEGER NOT NULL CHECK (ordinal >= 0),
  rect_x  REAL NOT NULL, rect_y  REAL NOT NULL, rect_w  REAL NOT NULL, rect_h  REAL NOT NULL,  -- what the detector flagged; image pixels, top-left origin
  cover_x REAL NOT NULL, cover_y REAL NOT NULL, cover_w REAL NOT NULL, cover_h REAL NOT NULL,  -- the padded cover a "Cover it" draws
  state   TEXT NOT NULL CHECK (state IN ('pending','notText','covered','tooSmall')),
  entry_id   TEXT,                        -- the Journal entry the picture is in (its cover for 'covered'); entries expire, so no FK
  finding_id TEXT,                        -- the finding that is this spot's cover in that entry ('covered')
  PRIMARY KEY (unchecked_id, ordinal),
  CHECK (state <> 'covered' OR (entry_id IS NOT NULL AND finding_id IS NOT NULL))
);
CREATE INDEX unread_spots_entry ON unread_spots(entry_id);
"""
}
