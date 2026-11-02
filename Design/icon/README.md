# Keo's icon

A K whose stem is a NAS cage: four bays in an enclosure, and an arm coming out of it.

## The construction rule

The arm is not placed next to the cage, it **derives** from it. Two ratios not to break:

- its thickness is one bay height (26 against 24);
- its two ends land on the axis of the first and the last bay (y = 78 and 174).

Changing the cage without recomputing the arm undoes the mark: it becomes two objects side by
side again.

## Palette

| | Background | Cage | Bays + arm |
|---|---|---|---|
| Any | `#e9a178` | `#cf8154` | `#ffffff` |
| Dark | *(transparent)* | `#7a4a30` | `#e9a178` |
| Tinted | *(transparent)* | `#6e6e6e` | `#ffffff` |

The cage is **always darker than its surroundings**, in all three variants. That luminance
ratio is what makes it exist; in tinted mode iOS keeps only the luminance, and a cage too close
to the background simply vanishes.

## The three variants

What iOS 18 asks for, verified against Apple's documentation, not assumed:

- **Any**: a **solid, opaque** square, with no rounded corners. The system does the masking.
  Rounding it yourself produces a fringe along the system mask.
- **Dark**: the mark on a **transparent background**. The system lays down its own dark
  background.
- **Tinted**: the mark in **greyscale**, on a transparent background. The system applies the
  user's tint from the luminance.

Without the last two, iOS makes them up on its own, and it does so badly on a two-tone mark.

## Rebuilding

```sh
python3 Design/icon/build.py
```

Writes the three master SVGs here and the three 1024² PNGs into
`Keo/Assets.xcassets/AppIcon.appiconset/`, with the `Contents.json` that declares the
appearances. The geometry lives in one place only, this script: do not retouch the SVGs by
hand, they get regenerated.

The masters contain **no stroke**: the arm is a filled outline (two half-circles of radius 13,
a round joint, a mitred inner tip). A stroke distorts under non-uniform scaling and does not
cut cleanly.

## Checking the variants made it through

An appearance missing from the compiled catalogue produces no build error:

```sh
xcrun assetutil --info ~/Library/Developer/Xcode/DerivedData/Keo-*/Build/Products/Debug-iphoneos/Keo.app/Assets.car \
  | grep -A1 AppIcon
```

Must show `(any)`, `UIAppearanceDark` and `ISAppearanceTintable`.

## What was tried and discarded

- **The doubled chevron** (storage depth): reads as "fast rewind", the K disappears.
- **One darkened bay** (the disk being read): reads as "missing disk".
- **The bay seam extended through the arm**: even reduced to 5 units, it severs the tip of
  the K, which is its hinge.
- **Latches, LEDs, ventilation grille**: under 2 px at 60 px. They clog up and look dirty.

## Going further on material

For a Liquid Glass icon (Xcode 26), import the SVG layers into **Icon Composer** and let it
lay down depth, material and reflections. Do not try to simulate them in the SVG.
