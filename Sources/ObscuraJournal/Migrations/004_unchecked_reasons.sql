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
