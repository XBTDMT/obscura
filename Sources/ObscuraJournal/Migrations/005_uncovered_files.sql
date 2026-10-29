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
