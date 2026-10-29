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
