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
DROP TABLE rules;
ALTER TABLE rules_v8 RENAME TO rules;
