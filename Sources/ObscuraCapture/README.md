# ObscuraCapture

roadmap: B-2 (folder watch, import, system state); the clipboard guard is B-4

The capture layer: everything that notices a new image and hands it to the engine as a `CaptureEvent`.
Spec: `knowledge/spec/ARCHITECTURE.md` §3 (isolation map, event flow), §4 rows 1–4 and 20, §7.
Depends on `ObscuraSupport` only (`WallClock` for TTLs, `Log.capture` with counts).

## Sources

| Type | Isolation | What it emits |
|---|---|---|
| `FolderWatcher` | `actor` over an `FSEventStream` on a private serial queue | `.file(url, origin:)` once the file has settled |
| `ClipboardGuard` | `@MainActor`, `Timer` in `.common` run-loop modes | `.pasteboardImage(data, uti:, changeCount:, preservedText:)` |
| `ImportSource` | plain struct | `.file(url, origin: .imported)` on `submit` |

All three conform to `CaptureSource`. Each owns **one** `AsyncStream` for its whole life: it survives
`stop()`/`start()` and finishes only in `deinit`. One consumer (the engine) iterates it. The buffer is unbounded,
because a clipboard image that is dropped is a leak path.

## FolderWatcher invariants

- Stream: `FileEvents | UseCFTypes | NoDefer`, latency 0.05 s, `sinceWhen = SinceNow` — nothing already on disk is
  ever scanned. FSEvents is recursive, so sub-folders of a root are watched too.
- Rebuilt only when the root set changes (`update(roots:)` compares as a `Set<WatchedRoot>`); empty roots → no stream.
- Filter order (row 2): `ItemIsFile && (Created || Renamed || Modified)` → not a dot-file → lowercase extension in the
  set → not in `ignoredPaths` (our writes, 5 s) → not in `recentlyHandled` (dedupe, 30 s) → regular file → creation age
  < 20 s → belongs to a root (longest resolved-path prefix gives the origin). Both TTL maps are pruned at the top of
  every batch using the injected `WallClock`.
- `Modified` is accepted so in-place writers are caught; the creation-age gate keeps old
  files out and `recentlyHandled` keeps a Created+Modified+Renamed burst to one event.
- Settle (row 3): poll `fileSize` + `contentModificationDate` every 50 ms until unchanged for 120 ms, cap 2 s, then emit.
  A file that vanishes while settling is dropped. Settle runs on `ContinuousClock`, not the wall clock.
- Raw FSEvents batches go through an ordered internal `AsyncStream` consumed by one task, so filtering is sequential and
  the dedupe map is never raced.
- Lifetime: `FSEventsStream` owns the C stream; its `deinit` does Stop/Invalidate/Release *on the stream's queue*, so no
  callback is in flight afterwards. The callback target is retained by FSEvents through the context's retain/release
  callbacks, never by a raw unretained pointer to a dying object.
- `ignore(url, for:)` is keyed by the resolved path string; register it **before** the atomic write.
- Logs: counts only (events per batch, accepted). No paths.

## ClipboardGuard invariants

- Tick cost when nothing changed: one `changeCount` read.
- Tick order (row 4): `changeCount != last` → skip our `ownWriteChangeCount` → skip while `trustedUntil > now` → skip if
  types contain `.fileURL` or any `skipTypes` (`ConcealedType`, `TransientType`) → PNG else TIFF → emit, carrying the
  `public.utf8-plain-text` representation if present.
- `writeBack` sets PNG + TIFF (+ preserved text) after `clearContents()` and records the resulting `changeCount`.
- `trust(for:)` is for ⌘C inside our own windows (default 2 s via `trust()`).
- `tick()` is internal so tests drive it without the run loop; the timer path is exercised by `start()`/`stop()`.

## System state (read-only here)

- `ScreenshotFolder.current(defaults:)`: `com.apple.screencapture` / `location`, tilde-expanded, must be an existing
  directory, else `~/Desktop`. `floatingThumbnailEnabled(defaults:)` reads `show-thumbnail` (default true). No
  `defaults`/`killall` here — the app layer decides whether to change system settings.
- `FolderAccess.probe`: `contentsOfDirectory` → `granted` / `denied` (EPERM, EACCES, Cocoa permission errors,
  anything else on an existing folder) / `missing`. Listing is what triggers the TCC prompt; re-probe on launch and on
  the maintenance timer.
- `LoginItem`: `SMAppService.mainApp` with `.requiresApproval` surfaced and `openSystemSettings()`.

## Tests

`Tests/ObscuraCaptureTests` — swift-testing, `.serialized` for FSEvents and the pasteboard. FolderWatcher tests use real
FSEvents on temp directories (each wait ≤ 2 s). ClipboardGuard tests use a private named pasteboard and never touch
`.general`. `LoginItem` is only read, never toggled.
