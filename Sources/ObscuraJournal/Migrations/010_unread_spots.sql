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
