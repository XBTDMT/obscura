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
DROP TABLE detector_overrides;
ALTER TABLE detector_overrides_v9 RENAME TO detector_overrides;
