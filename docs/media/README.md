# docs/media

The pictures and clips the README and the launch post use. Every one is drawn by Obscura's own code from made-up
sample data: no screen was captured, and every key in them is invented (the same generated values as the detector
fixtures in `Tests/Fixtures/text`).

| File | What it shows | Drawn by |
|---|---|---|
| `hero.png` | A terminal screenshot before and after Obscura | `SampleData.terminalPNG`, then a real `ShieldEngine` scan (Apple Vision OCR, the 84 detectors, the renderer, a temporary Journal): the "after" is the engine's own output |
| `catch.gif` | A catch: the screenshot, the covers snapping on, the corner card | The same engine output, one cover per finding, snapping on with the menu bar mark's snap timing (`MarkTimeline`, 0.18 s a piece, staggered); the card is `ThumbnailView`; the menu bar mark is `MarkRenderer` (Dissolving, Warm) |
| `menubar-marks.png` | The 16 menu bar marks in the Warm style on light and dark menu bars | `MarkRenderer` (the Classic ring through `MenuBarMarkImage`) |
| `journal.png`, `journal-dark.png` | The Journal window over six sample catches | `JournalContent` through `ViewSnapshot` |
| `viewer.png`, `viewer-dark.png` | The Viewer with one finding left visible (dashed outline) | `ViewerWindow` through `ViewSnapshot`; its toolbar pieces are drawn into the title band the window keeps for them |
| `settings.png`, `settings-dark.png` | Settings → Detectors with a made-up key in the test line | `SettingsWindow` through `ViewSnapshot` |
| `spotlight.png` | How a covered screenshot is listed in Spotlight | An illustration of Spotlight's panel; the title and file name are the real `CatchSearchItem` output for a real catch |
| `icon.png` | The app icon, 512 px | A copy of the app icon artwork |
| `x/launch-card.png` | 1600 × 900 card for the launch post | Icon, pitch and the hero's before/after |
| `x/catch.mp4` | 18 s, 1280 × 720, H.264, no audio: screenshot → covers → ⌘V paste → found in Spotlight by kind | Frames drawn with Core Graphics from the same pieces, written with AVFoundation |

The window pictures sit on the design system's desk colours with the window's corners, hairline and shadow; the
window buttons, keycaps, the plain menu bar strip, the message window and Spotlight's panel are drawn as illustrations
around Obscura's own pieces.

## Regenerating

On a Mac (Apple Vision has to run, so CI skips these):

```sh
OBSCURA_RENDER_MEDIA=1 swift test --filter MediaTests
```

That runs `ReadmeMediaTests` (hero, marks, Spotlight, GIF, launch card, MP4), `JournalMediaTests`,
`ViewerMediaTests` and `SettingsMediaTests`, and writes straight into this folder. Without `OBSCURA_RENDER_MEDIA=1`
those tests are skipped, so a plain `swift test` stays fast and writes nothing. Add
`OBSCURA_MEDIA_STILLS_DIR=<a scratch folder>` to also get PNG stills of the film's key moments for checking it by eye.

The tests check what they can: four covers in the catch, the Spotlight title's form, the GIF at most 6 s and 2 MB, the
MP4 under 15 MB. Look at every picture after regenerating; times and dates in the window pictures follow the clock.

The generators live in `Tests/ObscuraThumbnailUITests/MediaKit.swift`, `ReadmeMediaTests.swift`,
`Tests/ObscuraTestSupport/MediaOutput.swift` and one `*MediaTests.swift` file in each of the Journal, Viewer and
Settings test targets.
