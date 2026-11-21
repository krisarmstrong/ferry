# Ferry icon

A white ferry, bow to the right, carrying two files across the water: a green one behind and
a white one in front with its corner folded. It says what the app does: carry files across,
between an Android device and the Mac.

## Files

| Path | What it is |
| ---- | ---------- |
| `layers/background.svg` | Full-bleed 1024 gradient, `#1D3E94` → `#0E8597`. Used by the classic render; the `.icon` bundle sets the same gradient as its fill. |
| `layers/water.svg` | The water behind the hull, white at 12 % opacity. |
| `layers/wave.svg` | The water in front of the hull, over its keel, white at 18 %. |
| `layers/hull.svg`, `layers/cargo.svg` | Foreground glyph for 128 px and up: the hull with three portholes, and the two files. |
| `layers/hull-small.svg`, `layers/cargo-small.svg` | 32 px glyph, drawn on that size's pixel grid (1 px = 1024/26 units); no portholes. |
| `layers/hull-16.svg`, `layers/cargo-16.svg` | 16 px glyph on its pixel grid (1 px = 1024/14 units); no water. |
| `Ferry.icon/` | Icon Composer bundle (`icon.json` + `Assets/`). Light and dark fills; the hull and files use Liquid Glass. |
| `AppIcon.appiconset/` | Classic PNGs, 16–512 pt at 1x and 2x, with `Contents.json`. |
| `MenuBarGlyph-{16,18,22}.svg` | Black-and-alpha template glyph on 16, 18 and 22 pt grids. The app uses the 18 pt one. |
| `MenuBarGlyph-{16,18,22}{,@2x}.png` | Their renders, for review. |
| `Ferry.png` | 512 px render of `Ferry.icon` by Icon Composer's renderer, for the README. |

The generated files outside this folder:

| Path | What it is |
| ---- | ---------- |
| `Apps/Ferry/Assets.xcassets/MenuBarGlyph.imageset/MenuBarGlyph.svg` | Copy of `MenuBarGlyph-18.svg`, the status item's vector template. |
| `Apps/FerryProvider/Assets.xcassets/ferry.location.symbolset/` | Finder location symbol, from `MenuBarGlyph-18.svg`. |
| `Design/previews/icon-appearances.png` | `Ferry.icon` in every macOS 26 appearance: default, dark, tinted and clear, light and dark. |
| `Design/previews/icon-sizes.png` | Classic sizes on light and dark, with 8x zooms of 16 and 32 px. |
| `Design/previews/menubar-glyph.png` | The glyph in a menu bar beside system symbols, and each size's pixels at 1x and 2x. |
| `Design/previews/finder-location-symbol.png` | The location symbol beside Finder's own sidebar symbols. |

The 1024 canvas follows Apple's macOS grid: in the classic render the shape is an 824 px
continuous-corner square inset 100 px, with a shadow below. At 16 and 32 px the shape snaps to whole
pixels (14 px inset 1, 26 px inset 3) so the glyph edges land on the pixel grid. In `Ferry.icon` the layers are
full-bleed and the system applies the shape, glass and shadow.

## Render

From the repository root:

```sh
python3 Design/Icon/scripts/location-symbol.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Design/Icon/scripts/render.swift
```

`location-symbol.py` writes the Finder location symbol from the 18 pt glyph. `render.swift`
copies the layers into `Ferry.icon/Assets/`, rewrites every PNG listed above, and renders the
previews. It uses AppKit (`NSImage` reads SVG through CoreSVG), `actool`, and Icon Composer's
`ictool` from inside Xcode, so nothing needs installing. Edit the SVGs in `layers/`, never the
copies in `Ferry.icon/Assets/`.

To export one appearance by hand:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Design/Icon/Ferry.icon --export-image --output-file dark.png --platform macOS \
  --rendition Dark --width 1024 --height 1024 --scale 1
```

Renditions: `Default`, `Dark`, `TintedLight`, `TintedDark` (with `--tint-color` and
`--tint-strength`), `ClearLight`, `ClearDark`.

## Appearances

- **Default:** blue to teal gradient, white hull and files with glass.
- **Dark:** a darker gradient (`#0B1A44` → `#07505C`) set in `fill-specializations`; the
  glyph stays light.
- **Tinted and clear:** the system derives them from layer luminance. The hull and files are
  the bright shapes, so they carry the tint; the water stays faint.

## Menu bar

The status item draws `MenuBarGlyph` (a template image) at 18 pt, its intrinsic size. Every
straight edge sits on a whole point, so it lands on pixels at 1x and 2x; only the curves of the
hull and bow are anti-aliased. The 16 and 22 pt drawings are the same glyph on those grids, for
a smaller or larger menu bar if one is ever wanted.

## Finder location

A FileProvider domain has no icon of its own in the API. Finder's sidebar shows a domain with
the symbol its extension names in `CFBundleIcons` → `CFBundlePrimaryIcon` →
`CFBundleSymbolName`, as other FileProvider apps do. `FerryProvider`'s Info.plist names
`ferry.location`, a custom symbol in its asset catalog. It has one weight (Regular, medium
scale); the system scales it for the sidebar.

