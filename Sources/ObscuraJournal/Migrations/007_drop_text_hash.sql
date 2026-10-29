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
