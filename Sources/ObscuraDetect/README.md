# ObscuraDetect

roadmap: B-3

The detection layer: pattern specs and their generators, the confusable fold, the 84-detector catalogue,
validators, allow rules, block scope and the Scanner. Spec: `knowledge/spec/DETECTORS.md`; public API sketch:
`knowledge/spec/ARCHITECTURE.md` §7. Depends only on `ObscuraSupport` (and `ObscuraPrefs`, unused for now).
It never imports `ObscuraOCR`: the Engine maps OCR lines to `ScanLine(index:text:)`.

## Invariants

1. **Fold is 1:1.** `ConfusableFold.fold` replaces one scalar with one scalar, every table entry is BMP → BMP, so
   `fold(s).utf16.count == s.utf16.count`. Every `NSRange` the Scanner reports is therefore valid on both the folded
   and the original text. Ligatures (ﬁ ﬂ) are never folded. Property-tested in `FoldTests`.
2. **Compile options are always `[]`.** Case-insensitivity is inline `(?i)` in the pattern; prefix detectors stay
   case-sensitive. `ICURegexMatcher` is the only regex engine.
3. **`(?<secret>…)` is the part to redact.** `Finding.secretRange` is the named group, else the whole match.
   The renderer boxes `secretRange`, never `range`.
4. **Logs never carry text.** `Finding.textForLogs` is a SHA-256 hex digest of the matched text; log lines pass
   counts and ids only (`Log.detect`).
5. **Allow rules run first and beat validators.** Per line, allow ranges are collected before detectors run.
   A match fully inside an allow range is dropped in both modes; partial overlaps are trimmed (`.trim`, default,
   splitting in two when the allow range is interior) or kept whole (`.containedOnly`); a rule with
   `suppressPartialOverlap` drops partial overlaps in both modes. A block-scope line is skipped only when a
   `suppressPartialOverlap` rule covers the whole line.
6. **Union merge, first detector labels.** Ranged matches on one line that intersect on `secretRange` are merged;
   `detectorIDs[0]` is the earliest detector in catalogue order, every contributing id is appended, severity is the
   max. Adjacent-but-not-overlapping matches stay separate. Block findings never merge.
7. **Block scope fails closed.** A block runs from the trigger line to the first line containing every end marker
   (inclusive), and when no line does, to the end of the text: there is no line cap (security scan 2026-10-28 F20: a
   120-line cap left the rest of a long key visible). Its lines are consumed before any ranged detector runs and
   share one `blockID`.
8. **Validators are a closed enum.** `none, luhn, ibanMod97, entropy(min:), jwt, githubChecksum, awsKeyIdPrefix,
   phoneShape(minDigits:maxDigits:)`. `Detector.validatedPatternIndexes` restricts a validator to some patterns
   (GitHub checksum applies to classic tokens only; Supabase's JWT check applies to the service-role pattern only).
   `awsKeyIdPrefix` never rejects; it annotates `Finding.subkind`.
9. **User rules never throw.** `Catalogue.resolved` collects compile failures per custom or allow rule (UUID string)
   in `CompiledCatalogue.compileErrors` and drops that rule. An override (edited patterns) that fails to compile is
   reported in `overrideErrors` by detector id and the detector runs with its built-in patterns: fails closed.
   Only a built-in pattern failing to compile throws, and `CatalogueTests` makes that impossible to ship.
10. **Stable JSON.** snake_case keys via `CodingKeys`, string raw values for every enum, associated values as
    `{"type": …}` objects. Changing a Swift case name must not change the wire format.
11. **Every detector ships with fixtures.** `Tests/Fixtures/text/<id>.json` holds `{"positive": [...], "negative":
    [...]}`; `CatalogueTests.fixtures` fails for any detector without a file, any file without a detector, and any
    line that misbehaves. Every value is made up.
12. **Misread candidates ask, never decide (G-12 route C).** `MisreadCandidates` makes bounded variants of a line
    (measured confusions only: `l`/`1`/`I`, `O`/`0`, same-shape case flips, `_` read as a space, `<` runs, one dropped
    character) and puts them to the unchanged matchers and validators. A variant match counts only when it covers a
    changed unit and changes at most a quarter of the match; single swaps go only to checks no guess passes by chance
    (JWT header, GitHub CRC32), never Luhn, mod-97, entropy. The finding is reported at the read text's range.
13. **One label lexicon (G-12 route D).** `LabelTrust` uses the patterns of config.env.secret, config.labelled.password,
    config.yaml.secret and config.labelled.secret (G-16, plain-word labels) themselves to find labelled values for the
    engine's re-read trigger.
14. **Regex work is bounded (security scan 2026-10-28 F9/F14/F23).** Every built-in pattern is linear in the line's
    length, measured with ICU's own work counter on adversarial lines (`RegexWorkTests`). `RegexComplexity` refuses
    any `.regex` source over 1,024 UTF-16 units or with a repeat inside a repeat. At run time `MatchBudget` stops a
    search past 100 ms, a scan past 5 s, and any search of a cancelled task. `Scanner.check` reports the lines it did
    not finish (longer than 4,096 UTF-16 units, or stopped) and never calls them clean; `scan` is its findings alone.

## Adding a detector

1. Pick the id `<category>.<vendor>.<kind>` (regex `^[a-z]+\.[a-z0-9]+\.[a-z0-9]+$`); the first segment is the
   `Detector.Category` raw value. Ids are never reused.
2. Add a row to the right category array in `Catalog/BuiltInCatalogue.swift`, in the spec's order. Write the
   pattern from the vendor's public token format; never copy another product's regex. Use `.prefix(_, n:)` for a
   case-sensitive vendor prefix, `.regex` otherwise (raw strings `#"…"#`; use `##"…"##` when the pattern contains
   `"#`). Name the secret group when the pattern matches context.
3. Choose `validator` (and `validatedPatternIndexes` if it applies to some patterns), `scope`, `on:` (live
   credentials on, PII off unless a strong validator exists) and `severity` per DETECTORS.md §1 principles 2 and 12.
4. Add `Tests/Fixtures/text/<id>.json` with at least one positive and one negative line. Positives must pass the
   validator (compute checksums; do not guess). Lookaheads such as `(?=.*cloudflare)` need the keyword *after*
   the token on the same line.
5. Update the counts in `CatalogueTests.catalogueCounts`, `DetectorPersistenceTests` (Settings UI) and the totals line in DETECTORS.md §4.
6. `swift test --filter ObscuraDetectTests` must be green with zero warnings.

A new validator is a code change: add the case to `Validator` (with its `typeName` and coding), implement it in
`Validators`, give it positive and negative vectors in `ValidatorTests`, and document it in DETECTORS.md §5.
