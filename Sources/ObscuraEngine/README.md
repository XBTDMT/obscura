# ObscuraEngine

roadmap: B-2 (file pipeline), B-3 (detection), B-4 (clipboard), B-5 (Journal) — this package is where they meet.

`ShieldEngine` is the actor that composes the six built packages into the 22-step pipeline of
`knowledge/spec/ARCHITECTURE.md` §4, under the runtime rules of §3. It owns the state (in-flight scans, the compiled
catalogue, the pause flag, problems) and serializes decisions; every heavy stage runs off the actor in `Pipeline`.

## Files

| File | Role |
|---|---|
| `PipelineConstants.swift` | every constant of §4 as a named static, with the reason as its doc comment |
| `ScanOutcome.swift` | `redacted / clean / skipped(SkipReason) / failed(EngineError)`: the only four ways a scan ends |
| `EngineStatus.swift` | what the panel reads: `ProtectionState`, in-flight and queue counts, `LastCatch`, week stats, `Problem`s, `UncheckedFile`s |
| `ShieldEngine.swift` | the actor: `run()`, `submit(_:)`, `scan(...)`, `rerender`, `restoreOriginal`, `setFinding`, `pause/resume`, `catalogueChanged`, `maintenanceTick`, `retry(_:)`, `retryUnchecked()`, `loadUnchecked()`, `dismissUnchecked(_:)` / `restoreUnchecked(_:)`, `readText(of:in:)` (G-17), `status`, `events` (ordered `ScanEvent`s, G-9), `outcomes` |
| `KeyText.swift` | G-17: `KeyTextError`, and the pure half of `readText`: the area to re-read around a finding (`strip`), and which text of the reading is the key (`pick`: the detector's secret part whose cover overlaps the finding most, else the raw tokens inside it). Nothing is stored or logged |
| `Pipeline.swift` | decode, order+detect, box mapping, render, encode, TIFF, warm-up image: nonisolated, Sendable in and out |
| `CatalogueBuilder.swift` | Journal rules / overrides / state → `CompiledCatalogue` (+ problems for rules that do not compile or cannot be read on this Mac, G-30) |
| `StyleBridge.swift` | `StyleRecord` (Journal row, colour `"r,g,b,a"`) ↔ `StyleSpec` (renderer) |
| `Broadcaster.swift` | fan-out of status, scan events and outcomes to any number of `AsyncStream` consumers |

## Invariants

1. **No silent drops.** Every event that enters `submit` ends in exactly one `ScanReport` on `outcomes` (and one
   `.finished` on `events`, always after that scan's `.started`), and every non-success is logged on `Log.engine` by
   reason and counted with `record(stat: .skipped(reason:))`. Failures also feed `needsAttention` for
   `recentFailureWindow`; a file left without a verdict is kept as an `UncheckedFile` for `retry(_:)` until a later
   check of it reaches one (which also clears its failure) or the user dismisses it. The list is written through to
   the Journal's `unchecked` table and loaded from it once (`loadUnchecked()`, awaited by every reader and writer), so
   it survives a relaunch and never ages out with the failure window (G-13).
2. **One task per image, keyed.** `CaptureKey` is the resolved path or the pasteboard changeCount; a new event for a
   key cancels the older task. A cancelled scan writes nothing and ends `skipped(.cancelled)`. Cancellation is checked
   between stages up to the Journal write; after the entry exists the write-back always completes.
3. **OCR is serial and bounded.** All recognition goes through one `OCRQueue` (`maxQueuedScans`); clipboard images
   get `.clipboard` priority. An evicted file request is re-submitted `queueFullRetries` times, then `skipped(.queueFull)`.
   The engine races its own deadline (`timeout + 1 s`) on top of the recognizer's so a hung recognizer still ends in
   `skipped(.ocrTimeout)`.
4. **The recognizer owns the downscale.** `OCROptions.pixelBudget` comes from Settings; `ObscuraOCR` shrinks the OCR
   input and scales every rect back to full resolution, so the engine never rescales boxes (ObscuraOCR invariant 1).
5. **The catalogue is compiled once.** `catalogueChanged()` rebuilds it from the Journal; `scan` only reads it.
6. **Logs never carry text.** Counts, reasons, detector ids and milliseconds. The Journal stores no text and no hash of it (schema 7, fail-open #19). `readText(of:in:)` (G-17) returns a key's text to its caller and nothing else: it
   refuses unless `Settings.showsUncoveredKeyText` is on and the finding is uncovered, reads the original in memory,
   writes nothing (no Journal row, file, stat or cache) and logs only the finding id, its rect, the detector id (or
   "raw") and counts.
7. **Write-back follows Settings.fileHandling** and only for files that came from a watched folder (`origin` is
   `.screenshotFolder`, `.downloads` or `.watched`). Imports, CLI scans and demo scans never touch the file on disk.
   Before every write the path is handed to `folderWatcher.ignore`. `keepBoth` writes `<stem> (clean).<ext>`, where
   `<ext>` is the input's extension when it names the encoded container and the container's own extension otherwise
   (a PNG body never hides under a `.tiff` name). Clipboard write-back goes through `ClipboardGuard.writeBack`
   with PNG + TIFF made from the same rendered image. A new screenshot (a `.screenshotFolder` event, never a Check
   Again) that reaches a verdict, clean or covered, also puts its final picture on the clipboard through
   `ClipboardGuard.writeBack` while `Settings.copiesCleanImage` is on (G-18), so the guard never re-checks it; a skip or
   a failure writes nothing, so an unchecked original never reaches the clipboard.
8. **Journal before disk.** The entry (original + clean + findings) is created before the file is replaced, so an
   undo always has its bytes. The Journal stores the *encoded* container UTI (png / jpeg / heic).
9. **Warm-up at launch.** `run()` recognizes a 64×16 CoreText "warm" image first and logs the milliseconds; a cold
   Vision model load is 12–25 s (ObscuraOCR README) and must not land on the first real screenshot.

## Status

`status` is multi-consumer and replays the latest value to a new consumer. `ProtectionState` is `paused` when the
engine or `Settings.protectionPaused` says so, `needsAttention` for folder-access or recent scan failures,
`partlyProtected` when a guard is off in Settings or a source failed to start, else `protected`.

## Tests

`swift test --filter ObscuraEngineTests`: swift-testing, `StubTextRecognizer`/`ScriptedRecognizer` (no Vision),
a temp `SQLiteJournalStore`, `ManualClock`, `InMemorySettingsStore`. The run-loop suite uses a real `FolderWatcher`
on a temp folder (a 20-file burst, cancellation on a repeated key). The CLI's `fixtures verify` runs every detector's
fixture lines through the Scanner and exits 1 on a miss.
