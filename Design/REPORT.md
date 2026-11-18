# Visual identity and in-app help: report

## Designer's deliverables
- **App icon:** `Design/Icon/Ferry.icon` (Icon Composer bundle: blue→teal fill, darker dark-mode fill, Liquid Glass glyph layers); `AppIcon.appiconset` classic PNG fallback (source only, not built); 16/32 px glyphs drawn on their pixel grids; `scripts/render.swift` regenerates every PNG with AppKit only.
- **Menu-bar glyph:** `MenuBarGlyph.svg` (18 pt grid) + 16/18/32/36 px template PNGs; preferred over `externaldrive.connected.to.line.below`.
- **Help:** `help.json` (sections, steps, definitions, setup-guide links) and `Design/Help/README.md` (schema, window layout).
- **Docs:** `docs/user-guide.md`, README draft (now `README.md`).

## Integration
- `project.yml` adds `Ferry.icon` as a `wrapper.icon` resource with `ASSETCATALOG_COMPILER_APPICON_NAME: Ferry`; the built app has `Ferry.icns` + `Assets.car` and `CFBundleIconName = Ferry`.
- `Apps/Ferry/Assets.xcassets/MenuBarGlyph.imageset` (SVG, preserve-vector, template) is the `MenuBarExtra` label, with accessibility label "Ferry".
- `HelpView` (`Window("Ferry Help", id: "help")`): NavigationSplitView, SF Symbol sidebar, numbered steps shared with the setup guide (`NumberedSteps`), toolbar search with `ContentUnavailableView.search`, `@SceneStorage("help.section")`, links into the setup guide via `AppModel.showGuide(family:)`.
- Entry points: menu bottom-row `questionmark.circle` (⌘?), Settings "Ferry Help".
- All help strings in `Localizable.xcstrings` (58 keys); connection steps reuse `GuideSteps` keys.
- `HelpContentTests`: decoding, unique ids, SF Symbols exist, catalog coverage, `GuideSteps` parity, link targets, case/diacritic/Markdown-insensitive search.

## Not verified visually
Help window, menu-bar glyph in light/dark, Dock/Finder icon, icon dark/tinted/clear appearances — the screen was locked overnight.

## Concerns
- An incremental `xcodebuild` once embedded a stale, resource-less `Ferry_FerryUI.bundle`; a clean build was correct. Check the embedded bundle before shipping.
- `help.json` and `docs/user-guide.md` are kept in step by hand.
