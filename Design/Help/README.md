# In-app help

`Sources/FerryUI/help.json` holds Ferry's help in a compact form for a SwiftUI Help window. It mirrors
`docs/user-guide.md`; when one changes, change the other.

## Schema

```text
{ version, sections: [Section] }

Section  = { id, title, symbol, paragraphs?, steps?, definitions?, groups?: [Group], note?, link?,
             action? }
Group    = { title, paragraphs?, steps?, definitions?, note?, link?, action? }
link     = { title, target }    target: "guide", "guide:<DeviceFamily case>", "debugging" or
                                "debugging:<DeviceFamily case>"
definitions = [{ term, detail }]
action   = "removeFerry"
```

- `symbol` is an SF Symbol name (all checked to exist on macOS 26).
- `steps` render as a numbered list; `paragraphs` as body text; `definitions` as a two-column
  list (term in semibold).
- Strings use the same inline Markdown (`**bold**`) as the String Catalog. Step strings for the
  connection sections match the catalog keys in `Sources/FerryUI/Localizable.xcstrings`
  exactly, so the app can render them through `LocalizedStringResource` and share translations.
- Render order in a block: paragraphs, steps, definitions, note, link, action; a section's
  groups follow its own blocks.

## Window layout

A standard macOS window, opened from the **Help** item in the menu.

```text
┌──────────────────────────────────────────────────────────────┐
│ o o o            Ferry Help               [ Search        ]  │
├───────────────────────┬──────────────────────────────────────┤
│ [checklist] Getting…  │  Connect a NetAlly unit              │
│ [cable] Connect a N…  │  For the LinkRunner 10G, …           │
│ [phone] Connect ano…  │                                      │
│ [terminal] USB debu…  │  1. Connect a USB-C cable to the …   │
│ [wifi] Connect over…  │  2. On the unit: Settings → …        │
│ [folder] Using Ferr…  │  3. Tap Transfer files.              │
│ [menubar] The menu    │                                      │
│ [wrench] Tools over…  │  The device appears in Finder once … │
│ [wrench] Troublesho…  │                     [ How to Connect ]│
│ [hand] Privacy        │                                      │
│ [trash] Uninstall     │                                      │
└───────────────────────┴──────────────────────────────────────┘
```

Bracketed names stand for each section's SF Symbol (`symbol` in `help.json`).

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
  `DeviceFamily`. `"debugging"` and `"debugging:<case>"` do the same on the USB debugging steps
  instead of the file-transfer steps. This is the "How to Connect" deep link.
- An `action` renders as a bordered button after the link. `"removeFerry"` is **Remove Ferry…**
  under Troubleshooting: it asks to confirm, then removes Ferry's locations and helper and quits;
  if that fails, the reason shows under the button. Ferry has no Settings window, so this is
  where Remove Ferry lives.
- The window opens on the section the reader last chose, kept with `@AppStorage`, and on
  **Getting started** the first time (or when the remembered section no longer exists). The
  window itself is not restored at launch. The sidebar's selection and the detail always
  show the same section: the chosen one if the search shows it, else the first shown. Opening on **Troubleshooting** from a device in an error
  state is not built: the menu has one Help button, not one per device.
- Minimum size about 640 × 420; the sidebar is collapsible like any split view.
- Load `help.json` once from the bundle into `Decodable` structs; it is static content, so no
  observation is needed. If it is missing or does not decode, a fault is logged and the window
  shows "Help isn't available"; `make app` checks the built app carries it.
- Planned features ("Coming next") are in the user guide and README only, not in the app.
