# In-app help

`help.json` holds Ferry's help in a compact form for a SwiftUI Help window. It mirrors
`docs/user-guide.md`; when one changes, change the other.

## Schema

```text
{ version, title, sections: [Section] }

Section  = { id, title, symbol, paragraphs?, steps?, definitions?, groups?: [Group], note?, link? }
Group    = { title, paragraphs?, steps?, definitions?, note?, link? }
link     = { title, target }    target: "guide" or "guide:<DeviceFamily case>"
definitions = [{ term, detail }]
```

- `symbol` is an SF Symbol name (all checked to exist on macOS 26).
- `steps` render as a numbered list; `paragraphs` as body text; `definitions` as a two-column
  list (term in semibold).
- Strings use the same inline Markdown (`**bold**`) as the String Catalog. Step strings for the
  connection sections match the catalog keys in `Sources/FerryUI/Localizable.xcstrings`
  exactly, so the app can render them through `LocalizedStringResource` and share translations.
- Render order in a section: paragraphs, steps, definitions, groups, note, link.

## Window layout

A standard macOS window, opened from a **Help** item in the menu and in Settings.

```text
┌──────────────────────────────────────────────────────────────┐
│ ◉ ◉ ◉            Ferry Help              [🔍 Search        ]  │
├───────────────────────┬──────────────────────────────────────┤
│ ☑ Getting started     │  Connect a NetAlly unit              │
│ ⎓ Connect a NetAlly…  │  For the LinkRunner 10G, …           │
│ 📱 Connect another…   │                                      │
│ 📁 Using Ferry in…    │  1. Connect a USB-C cable to the …   │
│ ▭ The menu            │  2. On the unit: Settings → …        │
│ 🔧 Troubleshooting    │  3. Tap Transfer files.              │
│ ✋ Privacy            │                                      │
│ 🗑 Uninstall          │  The device appears in Finder once … │
│ 📅 Coming next        │                     [ How to connect ]│
└───────────────────────┴──────────────────────────────────────┘
```

- `NavigationSplitView` with a sidebar `List(selection:)` of sections, each a `Label(title,
  systemImage: symbol)`, and a detail `ScrollView` for the selected section. The system draws
  the sidebar's Liquid Glass material; no custom chrome or colours.
- Detail: the section title as `.title2` with `.bold()`, then the blocks in render order.
  Group titles are `.headline`. Numbered steps use the same row style as the setup guide
  (`SetupGuide.swift`): a monospaced-digit number in `.secondary`, then the step text.
- `.searchable(text:placement: .toolbar)` filters sections whose title or any string contains
  the query, case- and diacritic-insensitive; matching sections stay in the sidebar, the
  others hide. An empty result shows `ContentUnavailableView.search`.
- A `link` renders as a bordered button at the end of the block. `"guide"` opens the setup
  guide window with the model picker; `"guide:<case>"` opens it preselected to that
  `DeviceFamily`. This is the "How to connect" deep link.
- The window opens on **Getting started**, or on **Troubleshooting** when opened from a device
  in an error state. Remember the last section with `@SceneStorage`.
- Minimum size about 640 × 420; the sidebar is collapsible like any split view.
- Load `help.json` once from the bundle into `Decodable` structs; it is static content, so no
  observation is needed.
