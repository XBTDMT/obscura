# ObscuraRender

Paints findings over a decoded screenshot and encodes the result. Depends only on `ObscuraSupport`
(for `Log.render`). Spec: `knowledge/spec/ARCHITECTURE.md` §4 rows 15–19 and §7.

## Invariants

1. **Fill first.** `Redactor.render` draws the source once into one `CGBitmapContext` (source pixel
   size, source colour space if RGB else sRGB, 8-bit premultiplied-last RGBA). For every finding it
   clips to the rounded rect and *fills it* before anything else: solid colour (alpha forced to 1) or
   the sampled background. Blur and mosaic then draw a **synthetic** texture and run Core Image over
   that texture only. The filter never sees a pixel of the secret, so nothing can be un-blurred.
   Tests: `fillFirstLeavesNoOriginalPixelInsideAndNothingChangedOutside`, `textureIsIndependentOfSecretArrangement`.
2. **Texture is geometry-only.** `TextureSynth` draws bars (blur) or blocks (mosaic) from the box
   size, the text height and two colours. The PRNG is splitmix64 seeded from
   `(minX, minY, width, height, seedSalt)`; the secret's pixels, length and glyphs never reach it.
   Same inputs → byte-identical PNG; a different `RenderEnvironment.seedSalt` → a different texture.
3. **Outside the box, nothing changes.** The padded rect is snapped outward to whole pixels, so the
   anti-aliased clip edge lies inside it and every pixel outside is byte-identical to the input.
4. **Pixels are read by drawing**, never by trusting a source's byte layout (`PixelBuffer`).
5. **Metadata survives.** `ImageCodec` applies EXIF orientation on decode (the working image is `.up`)
   and re-attaches DPI with orientation `.up` on encode. PNG → PNG, JPEG → JPEG (q 0.92 default),
   HEIC → HEIC, everything else → PNG.
6. **Logs carry counts only** (`rendered N findings, skipped M, style <kind>`).

## Geometry

- `textH = max(1, finding.textHeight)`; `padX = max(2, padding × textH)`; `padY = max(2, min(0.16 × textH, padX))`.
- Padded rect ∩ image; skipped when < 1 px in either dimension; then `.integral` (after rounding away float dust).
- Corner radius `roundness × min(w, h) / 2`; findings are top-left origin, the context is flipped once per box.
- Blur: `CIGaussianBlur` radius `max(2, 0.3 × textH)`. Mosaic: `CIPixellate` scale `max(4, 0.34 × textH)`.
  Input is `clampedToExtent()`, output cropped to the box, composited inside the clip.
- Shared `CIContext` (`cacheIntermediates: false`, **software renderer**, sRGB working/output space) so
  the bytes are identical across runs and machines; the inputs are box-sized, so the CPU path is cheap.

## Background sampling (`BackgroundSampler`)

3-px ring around the padded rect (source pixels), per-channel **median** = background. **Ink** = mean of
inside pixels whose L1 distance from the median exceeds 0.45 (fallback: 0.85 grey on dark, 0.2 grey on
light). When the ring's mean per-channel variance exceeds 0.0004 (σ ≈ 5/255) the backdrop is treated as
a gradient: a least-squares line per channel against y, evaluated at the box's top and bottom edges;
Erase then paints a vertical linear gradient. Ring empty (box covers the image) → the inside stands in.

## Label (`LabelDrawer`)

CoreText bold system font `min(72, 0.5 × h)`, nothing below 6 pt. Fit test `lineWidth ≤ w − 0.8 × fontSize`,
fallback to the first word, then nothing. White @ 0.85 when the fill's luminance ≤ 0.5, else black @ 0.72.
Modes: `none`, `redacted` (the caller's localized word), `kind` (the finding's label).

## Tests

`swift test --filter ObscuraRenderTests`. Goldens live in `Tests/Fixtures/golden/<style>/page.png`
(synthetic scene, no real secrets); re-record with `OBSCURA_RECORD_GOLDEN=1`. Comparison tolerance is
2/255 per channel with a 0.1 % pixel budget.
