# Ferry icon

A white ferry hull carrying a document, on a deep blue to teal gradient with a soft band of
water. It says what the app does: carry files across, between a device and the Mac.

## Files

| Path | What it is |
| ---- | ---------- |
| `layers/background.svg` | Full-bleed 1024 gradient, `#1D3E94` → `#0E8597`. Used by the classic render; the `.icon` bundle sets the same gradient as its fill. |
| `layers/water.svg` | Water band, white at 16 % opacity. |
| `layers/hull.svg`, `layers/cargo.svg` | Foreground glyph for 128 px and up. |
| `layers/hull-small.svg`, `layers/cargo-small.svg` | Larger glyph with a wider gap, for 16 and 32 px. |
| `Ferry.icon/` | Icon Composer bundle (`icon.json` + `Assets/`). Light and dark fills; glyph layers use Liquid Glass. |
| `AppIcon.appiconset/` | Classic PNGs, 16–512 pt at 1x and 2x, with `Contents.json`. |
| `MenuBarGlyph.svg`, `MenuBarGlyph-{16,18,32,36}.png` | Black-and-alpha template glyph. |
| `Ferry.png` | 512 px render for the README. |
| `preview.png` | Review sheet: every size on light and dark, 8x zooms of 16 and 32 px, menu bar glyph. |
| `actool-render-256.png` | How `actool` renders `Ferry.icon` (the system's glass, not ours). |

The 1024 canvas follows Apple's macOS grid: in the classic render the shape is an 824 px
continuous-corner square inset 100 px, with a shadow below. In `Ferry.icon` the layers are
full-bleed and the system applies the shape, glass and shadow.

## Render

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Design/Icon/scripts/render.swift
```

It copies the glyph and water layers into `Ferry.icon/Assets/` and rewrites every PNG listed
above. It uses only AppKit (`NSImage` reads SVG through CoreSVG), so nothing needs installing.
Edit the SVGs in `layers/`, never the copies in `Ferry.icon/Assets/`.

To check the `.icon` bundle compiles and to see the system's rendering:

```sh
out=$(mktemp -d)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun actool Design/Icon/Ferry.icon \
  --compile "$out" --platform macosx --minimum-deployment-target 26.0 --app-icon Ferry \
  --output-partial-info-plist "$out/partial.plist"
iconutil -c iconset "$out/Ferry.icns" -o "$out/Ferry.iconset"
```

Open `Ferry.icon` in Icon Composer
(`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`) to preview the dark,
tinted and clear appearances.

## Appearances

- **Default:** blue to teal gradient, white glyph with glass.
- **Dark:** a darker gradient (`#0B1A44` → `#07505C`) set in `fill-specializations`; the
  glyph stays light.
- **Tinted and clear:** the system derives them from layer luminance. The glyph is the only
  bright shape, so it carries the tint; the water band stays faint.

## Menu bar

Recommendation: use `MenuBarGlyph` (as a template image) instead of the SF Symbol
`externaldrive.connected.to.line.below`. The symbol is a generic external drive that other
disk utilities also show; the glyph matches the app icon and reads cleanly at 18 px. Reasons
and the trade-off are in `Design/REPORT.md`.
