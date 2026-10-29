# ObscuraSearch

roadmap: B-5 · decisions: G-24, G-25

Covered files are findable by the kind of secret they hid, never by the secret (G-24): typing "Anthropic API key" in
Spotlight finds the covered screenshot, and (optionally) the covered file carries the Finder tags "Obscura" and the
kind of secret.

## Pieces

- `CatchSearchItem.build` — pure: a `CoveredFileRecord` + detector titles + thumbnail → `SearchItemContent` (title
  "Covered screenshot — Anthropic API key, Stripe secret key", keywords = kinds + category names + "Obscura",
  "covered", "redacted", creation date, file name, a PNG thumbnail of the covered file). A custom rule is always
  "Custom rule": its own title is the person's words and, unnamed, describes its pattern, which can be the secret.
- `SearchIndexing` — `CoreSpotlightIndex` (domain `io.github.xbtdmt.obscura.catches`, items never expire on their own)
  or a fake in tests. Tests never touch the Mac's real index.
- `TagPlan` + `FileTagging` — tag arithmetic that only ever adds or removes the tags Obscura recorded writing.
- `SearchCoordinator` — the lifetime. Records live in the Journal's `covered_files` table (schema 3, G-25), one per
  covered file, with a bookmark that follows a move or rename. Item and tags are made on a catch, updated on a
  finding toggle / Redo / new style, removed on Undo (the record stays for Redo), when the file is gone or in the
  Trash; launch runs a full reconcile (domain rebuilt from the records, so stale ids go), every maintenance tick a
  light one. Opening a result shows the viewer while the Journal entry exists, else reveals the covered file.
- Switches (Settings → Journal & Privacy): `indexesCatchesInSpotlight` and `tagsCoveredFiles`, defaults in
  `SearchIndexDefaults` (ObscuraPrefs), provisional until a test on an installed copy decides them.

## Invariants

- No recognized text, hash or anything derived from a value reaches this module: its inputs are detector ids,
  category raw values, a path, a date and the covered file's pixels.
- Search never fails a catch: errors are logged (counts and entry ids) and dropped.
- Logs carry counts and entry ids only.
