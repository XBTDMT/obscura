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
