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
