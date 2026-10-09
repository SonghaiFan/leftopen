# Legacy macOS app icon audit

Tracking: https://github.com/SonghaiFan/leftopen/issues/16

## Evidence, 2026-10-09

Remote main `f44d6d9` copies `Resources/AppIcon.icns` unchanged into the app;
`CFBundleIconFile=AppIcon` selects that resource. The repository contains no
Icon Composer `.icon` project or associated asset-catalog compilation.

All ten decoded representations reach all four canvas edges at alpha thresholds
1, 128 and 250. Rounded transparent corners do not provide outer margins.
The saved public 0.5.6 beta package has exactly the same ICNS SHA-256 as source:
`f0c9eb5af703b8471b3cd2a4ec2515f8a9fe6c33a343602f7efbf88cfdb35678`.

Commit `6d2b6cd` introduced a flattened image named
`assets/leftopen-iOS-Default-1024@1x.png`. Its SHA-256 equals the current
`docs/assets/AppIcon.png`; the latter is pixel-identical to the ICNS 1024px image.
This establishes flattened-image provenance, not the original export settings.

The confirmed packaging defect is missing outer padding in the legacy resource,
with no build-time adaptation. It explains the reported oversize consistently;
older-macOS Launchpad rendering has not been reproduced on this machine.
Do not attribute an Icon Composer bug or a specific export-mode choice without
the original project/export evidence.

## Minimal compatibility change

`Scripts/legacy-app-icon.swift` preserves the supplied source ICNS and scales
each representation uniformly onto a transparent canvas. No logo geometry,
colors, internal proportions or materials are redesigned. The project target is
100px inset per side at 1024px (824px artwork), rounded per representation.
This is an explicit compatibility policy pending visual acceptance, not a claim
that Apple requires this exact ratio. At 16px integer rounding produces 12px artwork;
small-size legibility therefore needs visual acceptance as well.

| Canvas pixels | Original bounds | Generated bounds (exclusive maximum) |
| --- | --- | --- |
| 16 | 0,0–16,16 | 2,2–14,14 |
| 32 | 0,0–32,32 | 3,3–29,29 |
| 64 | 0,0–64,64 | 6,6–58,58 |
| 128 | 0,0–128,128 | 13,13–115,115 |
| 256 | 0,0–256,256 | 25,25–231,231 |
| 512 | 0,0–512,512 | 50,50–462,462 |
| 1024 | 0,0–1024,1024 | 100,100–924,924 |

`build-app.sh` generates the packaged ICNS rather than copying it, then checks
the final selector, all ten slots/dimensions, padding and pixels against the
padding-only transform before signing. Expected pixels go through the same ICNS
encoding as the packaged icon, accounting for legacy color/alpha encoding, and
must match exactly after decoding. Original
full-bleed output, changed selectors, missing slots and double-padding are rejected.
CI runs six isolated packaging regression tests on both configured Mac runners.
Adding a native Icon Composer/asset-catalog integration must update this policy
explicitly; the verifier rejects an alternate icon selector or top-level Assets.car.

## Reproduce

```sh
swift Scripts/legacy-app-icon.swift audit Resources/AppIcon.icns
python3 Tests/test_legacy_app_icon.py
LEFTOPEN_OUTPUT_DIR=/path/to/new/output Scripts/build-app.sh
swift Scripts/legacy-app-icon.swift verify Resources/AppIcon.icns /path/to/new/output/LeftOpen.app
```

## Verification boundary

Pixel bounds, source preservation, generated-slot coverage, selector resolution
and complete local packaging are machine-checkable. Launchpad/Dock/Finder visual
parity on macOS 15 or earlier is still pending, as is newer-macOS visual regression.
Do not equate successful packaging with a confirmed visual fix. Avoid clearing
system icon caches or changing the installed app merely to obtain a screenshot.

To use the original layered workflow, supply the `.icon` project, its referenced
layer assets and export configuration. A flattened PNG cannot reconstruct those
materials or dynamic appearance variants faithfully.
