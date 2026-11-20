# In-app help

`Sources/FerryUI/help.json` holds Ferry's help as short task topics for the SwiftUI Help
window. `docs/user-guide.md` mirrors it, with an Install section added, and a test checks that
every Help string appears in the guide. When one changes, change the other.

## Schema

```text
{ version: 2, categories: [Category] }

Category = { title, topics: [Topic] }
Topic    = { id, title, symbol, paragraphs?, steps?, definitions?, groups?: [Group],
             messages?: [Message], note?, link?, action? }
Group    = { title, paragraphs?, steps?, definitions?, note?, link?, action? }
Message  = { message, cause, fix }
link     = { title, target }    target: "guide", "guide:<DeviceFamily case>", "debugging" or
                                "debugging:<DeviceFamily case>"
definitions = [{ term, detail }]
action   = "removeFerry"
```

- `id` is unique across topics. It is the selection the window remembers.
- `symbol` is an SF Symbol name. A test checks each one exists on macOS 26.
- `steps` render as a numbered list, `paragraphs` as body text, and `definitions` as a
  two-column list with the term in semibold.
- A `message` is the catalog key of a message Ferry shows, exactly as the code writes it, in the
  String Catalog of the module that shows it. Its wording is the key with each format specifier
  replaced by "…". That wording is a key in FerryUI's catalog, and Help shows it as the heading
  of the entry, then the `cause`, then the `fix`.
- Strings use the String Catalog's inline Markdown (`**bold**`). Every string is a key in
  `Sources/FerryUI/Localizable.xcstrings`. The connection and USB debugging steps match the
  `GuideSteps` keys exactly, so they share translations with the setup guide.
- Render order in a topic: paragraphs, steps, definitions, note, link, action, then groups, then
  messages.

## Troubleshooting entries

Every error, refusal and problem line Ferry can show has one entry, in a topic under the
Troubleshooting category. `HelpMessageCoverageTests` holds the table of every message key and
its topic. Every key in the FerryText, FerryAgentCore, FerryProviderCore and FerrySyncCore
catalogs must be in that table or listed as not a message, so a new message without Help fails
the build. FerryUI's messages are listed by hand. `HelpLinkTests` checks every case of
`TransportError`, `ToolFailure` and `WirelessOutcome`, and every fixed problem line
(`MenuStatusText`).

## Window layout

A standard macOS window, opened from **Help** in the menu (⌘?) or from a Help link beside a
problem.

```text
┌──────────────────────────────────────────────────────────────────┐
│ o o o  [^][v]          Ferry Help              [ Search        ] │
├─────────────────────────┬────────────────────────────────────────┤
│ GETTING STARTED         │  Device messages                       │
│  [info] What Ferry does │  What the menu says about a connected  │
│  [list] Turn on Ferry…  │  device, and what to do.               │
│ CONNECTING              │                                        │
│  [cable] Connect a ne…  │  ┌──────────────────────────────────┐  │
│  …                      │  │ The device was disconnected.     │  │
│ TROUBLESHOOTING         │  │ The device went away during …    │  │
│  [!] Device messages    │  │ Reconnect the device and try …   │  │
│  …                      │  └──────────────────────────────────┘  │
└─────────────────────────┴────────────────────────────────────────┘
```

- `NavigationSplitView` with a sidebar `List(selection:)`. Each category is a `Section` with its
  title as the header, holding one `Label(title, systemImage: symbol)` per topic. The detail is
  a `ScrollView` for the selected topic. The system draws the sidebar's material; there is no
  custom chrome.
- Detail: the topic title as `.title2` and bold, then the blocks in render order. Group titles
  are `.headline`. Each message is a rounded box: its wording in semibold, the cause in
  `.secondary`, then the fix. Topic titles, group titles and message wordings are VoiceOver
  headings.
- `HelpNavigator` holds the window's state and behaviour, so the tests drive it without drawing:
  - **Search.** `.searchable(placement: .toolbar)` narrows the sidebar to topics whose title or
    any string, messages included, contains the query. It ignores case, diacritics and Markdown.
    A category with no match is hidden. With no match at all, the detail shows
    `ContentUnavailableView.search`.
  - **Selection.** The sidebar and the detail always show the same topic: the chosen one if the
    search shows it, else the first shown. The topic is kept in `UserDefaults` (`help.topic`).
    The window opens on it, or on the first topic if it is unknown. The window itself is not
    restored at launch.
  - **Deep links.** A **?** beside a problem in the menu calls `AppModel.showHelp(forMessage:)`
    with the message's key and opens the window. The window takes the request when it appears,
    or at once if it is already open. It clears the search, selects the topic that explains the
    message, scrolls to the entry and tints it. Choosing another topic drops the tint.
  - **Keyboard.** The arrow keys move through the sidebar. Return in the search field opens the
    first match and moves focus to the sidebar. ⌘[ and ⌘] (the chevron buttons in the toolbar)
    go to the previous and next topic shown, across categories, and stop at either end.
- A `link` renders as a bordered button at the end of its block. `"guide"` opens the setup guide
  window with the model picker, and `"guide:<case>"` opens it on that `DeviceFamily`.
  `"debugging"` and `"debugging:<case>"` do the same on the USB debugging steps.
- An `action` renders as a bordered button after the link. `"removeFerry"` is **Remove Ferry…**,
  the Troubleshooting category's last topic. It asks to confirm, then removes Ferry's locations
  and helper and quits. If that fails, the reason shows under the button. Ferry has no Settings
  window, so Remove Ferry lives here.
- The minimum size is about 680 × 440. The sidebar collapses like any split view.
- `help.json` is loaded once from the bundle into `Decodable` structs. If it is missing or does
  not decode, a fault is logged and the window shows "Help isn't available". `make app` checks
  the built app carries the file.
- Planned features are in the README only, not in the app.
