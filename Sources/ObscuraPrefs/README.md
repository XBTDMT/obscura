# ObscuraPrefs

Typed scalar settings for Obscura, backed by `UserDefaults`. Spec: `knowledge/spec/ARCHITECTURE.md` §6 (the key table) and §7 (`SettingsReader`). Depends only on `ObscuraSupport`.

## What lives here and what does not

- Here: every scalar preference in the §6 table as a field of `Settings`, its default, its `UserDefaults` key (`SettingsKey`), and the stores that read and write it.
- Not here: rules, detector overrides, detector state and redaction styles. Those are list-shaped and live in SQLite owned by `ObscuraJournal`.
- Never stored: `openAtLogin` (read live from `SMAppService`). `trial.endNoticeShown` is out until a trial exists (§12).

## API

| Type | Role |
|---|---|
| `Settings` | `Codable, Sendable, Hashable` value with every field and its default. JSON keys are the `SettingsKey` strings. |
| `SettingsKey` | `String, CaseIterable` enum of the exact `UserDefaults` keys. |
| `FileHandling`, `JournalRetention`, `AllowRuleMode`, `Appearance`, `JournalView` | String-raw enums (retention is Int-raw: 1, 24, 168, 720 hours). |
| `SettingsReader` | `current()` plus `changes: AsyncStream<Settings>`; each access to `changes` is an independent stream. |
| `SettingsWriter` | adds `update(_ transform:)`, atomic, emits once per real change. |
| `UserDefaultsSettingsStore` | the production store. |
| `InMemorySettingsStore` | tests and the `obscura` CLI. |
| `SettingsMigration` | `migrateIfNeeded(defaults:)`, `settings.schemaVersion`, currently 2 (2: the Boolean `protection.paused` became the date `protection.pausedUntil`; a stored `true` becomes `Date.distantFuture`). |

## Invariants

1. Every `SettingsKey` has a registered default (`register(defaults:)` at store init). `object(forKey:)` is never `nil`, so "absent" never silently means "default". `language` registers as `""` (the registration domain cannot hold `nil`); `""` reads back as `nil` = system. `protection.pausedUntil` registers as `Date.distantPast`, which reads back as `nil` = protecting; a stored value that is not a date also reads as protecting.
2. Stored values are read with their exact type. A Bool stored as a number, a retention of 5, a non-positive OCR budget, an unknown enum raw value: each is coerced to its default and logged on `Log.app` by key name only. Nothing throws, nothing is rewritten on read.
3. `update` reads, transforms and writes under one lock, writes only the keys that changed, and emits the new `Settings` exactly once. A no-op transform emits nothing.
4. Changes made to the same `UserDefaults` from elsewhere in the process are observed via `UserDefaults.didChangeNotification`, debounced (50 ms by default), re-read and emitted only if the value differs from the last emitted one. That notification is in-process only: an edit with the `defaults` tool from another process is picked up on the next `current()` or the next in-process change, not pushed.
5. `changes` never replays the current value; call `current()` first.
6. The schema version is stored only after a migration step completes, so a crash mid-migration re-runs that step on the next launch. Renames go in `SettingsMigration` and nowhere else.

## Tests

`Tests/ObscuraPrefsTests` runs every store conformance case against both stores through one generic helper, using a throwaway `TestDefaults` domain (Tests/ObscuraTestSupport): its plist lives in a private temporary folder, never in ~/Library/Preferences, and is cleared and removed when the test process exits.
