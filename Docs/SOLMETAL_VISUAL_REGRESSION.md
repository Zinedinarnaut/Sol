# SolMetal visual regression

The compatibility runner tells us whether a title boots, presents frames, and
paces cleanly. This companion answers a different question: did SolMetal draw
the same scene as the reference backend?

It is deliberately offline. It never starts Sol, stops a game, reads keys or
firmware, or changes a capture. It compares paired files that a developer has
already collected.

## Set up a private suite

Create the default owner-only manifest:

```sh
python3 script/solmetal_visual_regression.py init
```

The manifest lives outside the repository at:

```text
~/Library/Application Support/Sol/Developer/SolMetalVisualRegression/suite.private.json
```

Capture the same warmed checkpoint with the reference backend and SolMetal.
Keep the title version, update/DLC set, resolution, aspect ratio, camera,
shader-cache state, and UI overlays unchanged. Do not resize either image.

Add one entry for each pair:

```json
{
  "schemaVersion": 1,
  "private": true,
  "comparisons": [
    {
      "id": "totk-cave-warm",
      "scene": "beneath-castle",
      "tileSize": 64,
      "reference": {
        "title": "totk",
        "backend": "moltenvk",
        "path": "/private/path/totk-reference.png",
        "format": "png"
      },
      "candidate": {
        "title": "totk",
        "backend": "solmetal",
        "path": "/private/path/totk-solmetal.png",
        "format": "png"
      },
      "tolerance": {
        "maxMismatchPercent": 0.25,
        "maxMeanAbsoluteError": 0.00392157,
        "maxP95ColorDistance": 0.01,
        "maxMeanLumaError": 0.005,
        "maxChangedTiles": 8,
        "maxDarkRectangles": 0
      }
    }
  ]
}
```

`reference.title` and `candidate.title` must match. Titles, scenes, comparison
ids, and backend names are public-safe aliases; local filenames and paths never
enter the public report. The manifest and every raw capture must stay outside
the repository.

Validate the metadata, then compare:

```sh
python3 script/solmetal_visual_regression.py validate
python3 script/solmetal_visual_regression.py compare \
  --output solmetal-visual-results.json
```

An explicit tolerance turns a changed pair into either `within-tolerance` or
`regression`. Without one, a changed pair is `changed-unrated` and is left for
review. Add `--strict` when an unrated change should fail the command. The
public JSON is still written when a regression fails so CI has useful evidence.

## Presentation transfer regression

Run the built-in color-transfer gate without a game, private capture, or GPU:

```sh
python3 script/solmetal_visual_regression.py transfer-regression \
  --output solmetal-color-transfer-results.json
```

The fixture is a 256-level grayscale ramp. The correct contract preserves each
encoded sRGB byte when the final display target is `BGRA8Unorm`. The modeled
failure samples an sRGB texture—which decodes it to linear—and writes those
linear values directly into `BGRA8Unorm` without re-encoding. Grayscale makes
the result independent of RGBA/BGRA channel order. Float-to-UNORM conversion is
modeled with nearest-even rounding.

The fixed signatures are:

| Artifact | Signature |
| --- | --- |
| Correct encoded ramp | `f7721524360322232937cff69886be54d18f94dc172627061757855971b5db36` |
| Decoded-linear values in UNORM | `38054d3b7822df8e784644befb2be76c3f98958ebfc799d7294ba5cdada6b142` |
| Visual difference fingerprint | `a6000a270eecd503d54512dd` |

The canonical mismatch must cross all four detection thresholds:

- at least 99% exact pixel mismatch;
- at least 0.18 mean absolute RGB error;
- at least a 25 percentage-point increase in retained-black pixels;
- a p50 luminance delta no greater than -0.17.

The known failure currently produces 254/256 changed pixels (99.21875%),
0.18897059 mean absolute error, a 27.34375-point retained-black increase, and a
-0.17529297 median-luminance shift. These margins are deliberately much larger
than one-byte quantization noise.

This command verifies the detector and its signatures; it does not prove the
live `CAMetalLayer` path. For live proof, capture the same unscaled 256-level
ramp before and after presentation and add it as a normal private comparison.
Use maximum mean RGB and p95 color errors of `1 / 255` as the initial acceptance
limits. A canonical missing sRGB re-encode exceeds those limits by a wide
margin. Do not add a compensating gamma pass unless the captured pre-layer ramp
is correct and the displayed ramp matches this failure signature.

## Four-title pass

Use four stable aliases and checkpoints in the same private manifest:

| Alias | Suggested checkpoint | What it exercises |
| --- | --- | --- |
| `totk` | warmed cave or open-world save | HDR composite, depth, terrain, effects |
| `mk8` | fixed camera at the start of a race | post-processing, particles, UI, pacing |
| `arceus` | fixed outdoor save | vegetation, distance, lighting, alpha |
| `sm3dw` | fixed level entrance | geometry, shadows, color, UI |

For each title, capture at least one reference/SolMetal pair at the exact same
internal and output resolution. A second pair from a visually different scene
is more useful than several copies of one title screen. Run all entries with
one `compare` command; the result retains the title and scene aliases so it can
sit beside `solmetal-compatibility-results.json`.

## Supported inputs

- Non-interlaced, 8-bit PNG screenshots. RGB, RGBA, grayscale, grayscale-alpha,
  and indexed PNGs are decoded without third-party packages. PNG metadata and
  compression differences are ignored.
- Headerless `rgba8`, `bgra8`, `rg11b10float`, and `rgba16float` framebuffer
  dumps. Raw entries require `width` and `height`; add `rowBytes` when rows have
  padding. Raw words and half floats are little-endian.
- Set `flipY: true` on one capture only when its raw framebuffer origin differs.
  The tool performs no other alignment, crop, scale, or color matching.

Reference and candidate formats and dimensions must match after decoding. This
is intentional: automatic resampling can hide a renderer or surface-sizing
regression.

## Reading the report

`exactMismatchPixels` compares decoded pixels, so PNG container metadata does
not count as a change. `meanAbsoluteError` and `maxAbsoluteError` use normalized
display-channel values and are broken out into red, green, blue, and alpha.

The perceptual section adds luminance-weighted color distance, p95 color
distance, and horizontal/vertical edge error. These are deterministic triage
signals, not a claim that two frames are perceptually identical. HDR dumps are
mapped through a fixed `x / (1 + x)` display curve before these metrics.

The luminance section reports deterministic p1, p50, p95, and p99 values for
both captures and their signed candidate-minus-reference delta. Luminance is
linear Rec. 709 after the same fixed HDR display mapping and is quantized to
4,096 steps for stable percentile results. `clippedWhitePercent` is the share
of pixels with luminance at or above 0.98; `retainedBlackPercent` is the share
at or below 0.02. Their delta fields are signed percentage-point changes, so a
positive clipped-white delta or negative retained-black delta makes a washed
candidate immediately visible. Alpha is not part of these measurements.

Tile diagnostics default to 64×64 pixels. They report changed and fully changed
tiles, the eight worst locations, each tile's dominant error channel, and the
exact difference bounds. This makes tile-aligned corruption visible without
putting either screenshot in a public artifact.

`darkRectangles` is a focused diagnostic for new near-black rectangular blocks.
It builds a deterministic four-connected mask from candidate pixels whose
linear Rec. 709 luminance is at most `0.02`. A component is reported only when
it is at least 8×8 and 64 pixels, fills at least 90% of its axis-aligned bounds,
has at least 90% edge regularity, differs from the reference in at least 80% of
its pixels, and lowers mean luminance by at least `0.04`. Those reference checks
keep an unchanged black UI panel or letterbox from being labeled as a new
renderer artifact. Irregular dark silhouettes are retained in the component
count but are not rectangles.

Each detected rectangle includes exact bounds, area, fill and edge regularity,
changed-pixel rate, interior reference/candidate luminance, candidate RGB means,
and a component fingerprint. `darkMaskFingerprint` identifies the complete
near-black mask; `rectangleMaskFingerprint` identifies the qualified rectangle
set. Capture dimensions and detector version are included in both signatures,
so compare fingerprints only for the same checkpoint and resolution. Set
`maxDarkRectangles: 0` in a comparison tolerance to turn a detection into a
regression. The detector is intentionally conservative and does not make a
single unpaired screenshot proof of a renderer bug.

## Offline test

```sh
python3 script/test_solmetal_visual_regression.py
```

The tests generate temporary PNG, RGBA8, and R11G11B10 fixtures. They cover
exact matches, localized tile changes, channel and edge diagnostics,
deterministic luminance distributions, clipped-white and retained-black deltas,
the canonical sRGB-to-UNORM transfer failure and signatures, deterministic dark
rectangle detection and false-positive rejection, tolerance exit codes,
cross-title rejection, owner-only manifests, and public path redaction.
