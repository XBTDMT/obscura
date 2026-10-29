# ObscuraOCR

roadmap: B-2

On-device text recognition for the pipeline (ARCHITECTURE.md §3 isolation map, §4 rows 5–7 and 13, §7). Depends only on `ObscuraSupport`.

## Pieces

| Type | Role |
|---|---|
| `OCRLine`, `GlyphBoxProvider` | one recognized line: `index`, `text`, `rect` (image px, top-left origin, full resolution), optional `candidate` that answers sub-range boxes. Equality and hashing ignore the candidate. |
| `OCROptions` | `.accurate`, language correction off, 20 s timeout, 24 MP pixel budget, 4096 px longest side. |
| `TextRecognizer` | the protocol the engine depends on. `VisionTextRecognizer` is the real one; `StubTextRecognizer` is for tests and CI. |
| `VisionTextRecognizer` | Swift Vision API `RecognizeTextRequest` (`automaticallyDetectsLanguage = false (pass 1 reads the user's languages plus English, G-31)`, whole image, `topCandidates(1)`), keeps the `RecognizedText` behind a `GlyphBoxProvider`. |
| `DownscalePlan` / `Downscaler` | the pixel-budget shrink and the exact scale-back. |
| `Deadline` (internal) | the timeout race. |
| `OCRQueue` | serial, bounded, two-class FIFO: one Vision request at a time, clipboard ahead of file. |
| `LineOrdering` | reading order (rows by midY within half a line height, then minX); reassigns `index`. |
| `BoxMapper` | finding range → pixel rect: token widening, Vision box with acceptance test, proportional fallback, glyph-grid cells (`GlyphGrid.cover`), padding, clipping; `wholeLineRect` for block findings. |
| `RecallReader` | G-12 routes A and B: pass 1 (`TextRecognizer.read`: lines + text regions), the caller's label trigger, `RereadPlanner` bands, one `RereadSheet` request (a strip that comes back empty or, G-22, short of its ink is retried at the other `retryScales`, keeping its best reading), `TileStitcher` lines. Runs inside one `OCRQueue.withTurn` and one deadline; a re-read that cannot finish keeps pass 1. A band still short of its ink after the retries marks its lines `shortRead` (G-22). A band with no text at all after the retries gets G-32's bounded last attempt (full-width crop at 1×, accurate; then `.fast` only if that read nothing; each only inside the deadline), recorded in `ReadCompleteness.lastAttempts`. |
| `ReadCoverage` / `ReadCount` / `ShortRead` / `InkProfile` | G-22: a reading's non-space units and covered ink against the band's ink (`InkCells.profile`: grid cells, else column runs); `isShort` past `RecallTuning.shortReadTolerance`; `ShortRead.inkEnd` is the end of the ink a cover continues on. |
| `RereadPlanner` / `RecallTuning` | which lines are read again (long, split, ends before its ink, flagged label) and which text regions nobody read; bands, overlapping tiles, scale. |
| `RereadSheet` | stacks enlarged strips on one image and maps observations back to full resolution. `render` is public: the engine draws the area of one uncovered key the same way to read its text on demand (G-17). |
| `TileStitcher` / `CharacterBoxes` | joins overlapping tile readings on their longest common run (geometric fallback), one box per UTF-16 unit; a strip's duplicate fragment (an observation mostly inside a longer one) is dropped (`distinct`, G-22). |
| `InkCells` / `GlyphGrid` | per-cell ink measured from the pixels of a finding's row, the monospace grid it fits, and the cells a cover takes. A word's run of ink bridges one empty cell when the run falls short of the word by more than the tolerance: the read dropped a space the ink has (`(212) 555-0199` read `（212）555-0199`). |

## Invariants

1. **Every rect is in full-resolution image pixels, top-left origin.** When OCR ran on a downscaled copy, line rects and every glyph box are multiplied back by `fullSize / workSize` per axis before they leave this package; nothing downstream knows a downscale happened.
2. **The downscale never changes what the renderer sees.** Only OCR input is shrunk (longest side `maxLongestSide`, and by the area ratio if that still exceeds the budget). The caller keeps the original `CGImage` for rendering.
3. **Every recognition ends in lines or an `OCRError`** (`timeout`, `failed(underlying:)`, `cancelled`, `badImage`, `queueFull`). Nothing is dropped silently; a zero-sized image is `badImage`, not an empty result.
4. **The timeout holds even if Vision ignores cancellation.** `Deadline` races a detached task against `Task.sleep` through a one-shot continuation, so the caller returns at the deadline; the Vision task is cancelled and its late result is discarded.
5. **One Vision request at a time.** `OCRQueue` runs exactly one recognition; `.clipboard` requests go ahead of every waiting `.file` request and are never evicted or refused. When the waiting list is at `maxQueued`, the oldest waiting `.file` request is resumed with `queueFull` so the engine re-submits it (the file is still on disk). A cancelled waiter leaves the queue with `cancelled`. `depth` = running + waiting.
6. **Reading order is total and deterministic.** Lines are sorted by `midY`, grouped into rows while each line's center is within `0.5 × mean(height)` of the row's first line, then ordered by `minX` inside a row. Ties fall back to the recognizer's index. `index` after `readingOrder` is the position in the result.
7. **A cover never cuts a token.** `BoxMapper.widenToToken` grows the range outward to whitespace or a framing character (`BoxMapper.isTokenBoundary`) (`= : , ; @` quotes, brackets, and the curly quotes the Scanner folds) on both sides, in UTF-16 units, clamped to the text. It stops after a `://` scheme separator, and a side whose extension holds no ASCII at all (OCR noise for a delimiter) stays at the match.
8. **Vision geometry is preferred, never trusted blindly.** A provider box is used only when its width > 1 px and it intersects the line rect inset by −4 px; otherwise the proportional estimate (UTF-16 count across the line rect, full line height). Either way the result is padded by half a glyph width (box width ÷ range length; `lineHeight × 0.25` for an empty range) plus the caller's `padding`, and clipped to the line rect inset by −2 px. A box that survives acceptance but clips to nothing falls back to the estimate. When the row's ink fits a monospace grid (`InkCells`, G-12), the cover takes whole cells (`GlyphGrid.cover`) with a tenth of an advance of slack, and clips to the line's ink extent.
9. **A short re-read is never trusted (G-22).** Every re-read band's final reading is counted against its ink; a band still short after the bounded retries is logged (`reread short: band N units X of ink Y …, fallback cover`, counts only) and its lines carry `shortRead`, which the engine turns into covers that run to the end of the line's ink.
9a. **An unread band gets one bounded last attempt, never more time (G-32).** A band that every re-read sheet and retry left with no text is cropped at the image's full width, scale 1, and read with the accurate level in pass 1's languages; only if that reads nothing, the same crop at `.fast`. At most two calls per band, each made only while the deadline leaves `minimumRereadBudget`, with the time left as its timeout. A `.fast`-only reading is read but its lines carry `shortRead` with cause `.fast` (G-22's conservative cover). A band still unread stays in `completeness.incomplete` exactly as fail-open #1 left it.
10. **Logs carry counts only.** `Log.ocr` records line counts, pixel counts, downscale flag, elapsed ms and queue depth. Recognized text never reaches a log, an error payload or a test assertion message.
11. **Correction stays off by default.** `usesLanguageCorrection = false` because correction rewrites keys toward dictionary words. `automaticallyDetectsLanguage = false (pass 1 reads the user's languages plus English, G-31)` so non-English UI text around a secret still recognizes.

## Known behavior worth planning for

- The first `.accurate` request in a process loads Vision's models: 12–25 s measured on this Mac (2026-10-26, Apple silicon). Warm requests on a 700×120 image take ~0.07 s. The engine should issue a warm-up recognition at launch (a tiny blank image) or the first real screenshot can hit the 20 s timeout.
- `Deadline` leaves a Vision task running after a timeout until Vision honors the cancellation; the queue is already free for the next image.

## Tests

`Tests/ObscuraOCRTests`: reading order, token widening, BoxMapper accept vs fallback, downscale arithmetic and render, queue priority / serialization / eviction / cancellation, timeout race, and one Vision smoke test that renders a made-up `TOKEN=abc123xyz789` with CoreText (skipped when `CI` is set).
