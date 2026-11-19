# Ferry — design

Status: draft for owner approval · 2026-11-17

## Intent

Plug an Android phone into a Mac and have it show up in Finder like any other
drive: browse, open, copy, rename, delete — from Finder and from any app's open
and save panels. A free, MIT-licensed, native macOS alternative to MacDroid
(commercial) and OpenMTP (an Electron file-manager window with no Finder
integration).

Personal project of the owner, on their own GitHub (`krisarmstrong/ferry`,
public), MIT. Not an MSN product; MSN product rules (BUSL, tiers) do not apply.

Name: **Ferry** (owner decision 2026-11-17). Bundle IDs and the GitHub repo
use `ferry`.

## Goals (v1)

1. USB connection over MTP. Phone appears in Finder's sidebar under Locations
   within a few seconds of the user tapping "File transfer" on the phone.
2. Each storage (internal, SD card) is its own Finder location.
3. Browse folders; open files in any app (downloaded on demand).
4. Copy files and folders both directions, including files > 4 GB.
5. Create folder, rename, delete on the phone.
6. Unplugging mid-operation fails that operation cleanly with a clear error;
   nothing hangs Finder; the location disappears.
7. A small menu-bar item showing connected devices, transfer progress, a
   refresh action, and setup help when the phone isn't detected.

## Target devices (owner decision 2026-11-17)

Ferry is built first for **NetAlly Android-based testers**; generic Android phones are
supported as a bonus, never at a NetAlly device's expense.

- **v1 targets:** LinkRunner 10G, EtherScope nXG, LinkRunner 100G. The owner says these share
  one Android 8 board; NetAlly's user guides give identical USB steps for all three but state
  no Android version.
- **Later:** AirCheck G3 (different board, different steps).
- Verified so far: LinkRunner-100G (see `docs/TESTING.md`).

## Setup guide: "Enable file transfer" (owner requirement)

Most "it doesn't work" reports will be a device that is connected but not in file-transfer
mode: it enumerates over MTP but publishes no storage (seen on the LinkRunner-100G until
**Transfer files** was chosen). Ferry must say so and show how to fix it.

- **When it appears:** (a) a device is detected but reports no storage
  (`TransportError.deviceLocked`); (b) nothing is detected for a few seconds after the menu
  opens; (c) from a permanent "How to connect" item in the menu and Settings. A short
  one-line reminder ("Choose Transfer files on the device") sits in the empty and transfer
  views.
- **Picks the right steps:** when the device is identified, show its model's steps; otherwise
  show a model picker (NetAlly models first, then "Other Android phone").
- **NetAlly LinkRunner 10G / EtherScope nXG / LinkRunner 100G** (source: each model's
  AllyWare 3.x user guide, "Using a USB Type-C to USB Cable"):
  1. Connect a USB-C cable to the **USB-C port on the left side** of the unit and to the Mac.
  2. On the unit: **Settings** (bottom of the Home screen) → **Connected devices** → **USB**.
  3. Tap **Transfer files**.
  The guides only say "PC or tablet" and never mention a Mac; Ferry's guide fills that gap.
- **Other Android phones** (generic; to be checked on a real phone before shipping):
  - Android 8–9: pull down the notification shade → tap **USB charging this device** →
    **Transfer files**.
  - Android 10 and newer: notification **Charging this device via USB** → tap → **USB
    preferences** → **File transfer**. Or Settings → Connected devices → USB.
  - Unlock the phone first; storage stays hidden while it is locked.
- **Form:** a SwiftUI sheet with numbered steps, SF Symbols, and per-model screenshots once
  the owner supplies them (NetAlly screenshots must be the owner's own captures). Strings
  live in the String Catalog. `ferryctl` points to the same steps in its unlock message.
- **No vendor impersonation:** NetAlly model names are used factually to identify devices;
  no NetAlly logos or branding in Ferry.

## Non-goals (v1)

- Finder badges (the Finder Sync extension adds menu items only; see ADB).
- A native ADB engine (future release; see ADB).
- "Keep offline" pinning beyond what the system provides.
- Auto-update (Sparkle), localisation beyond English (but strings go in a
  String Catalog from day one), Intel builds.
- Photo/camera (PTP) import — Image Capture already does that.
- **Packages** (amended 2026-11-18, round-8 scope ruling). Ferry copies files
  and plain folders only. A package (any type conforming to `com.apple.package`
  or `com.apple.bundle`: an `.rtfd` or Keynote document, an app, plug-in,
  framework or extension) is one item to FileProvider but a folder on the
  device, and keeping it opaque cost most of rounds 6-8's risk (an archive
  transport, a tree writer, budgets, link loss) for near-zero value to NetAlly
  users, whose files are reports, captures, screenshots and scripts. Creating
  one on the device fails for good (`cannotSynchronize`) with "Packages and app
  bundles can't be copied to the device. Compress it into a .zip first." A
  folder is a package by its type or, since `cp -R` sends a plain folder first,
  by its name. On the device every folder is presented as a plain folder
  (content type `public.folder`), whatever its name, and its children are
  ordinary items. macOS still types a folder on disk by its extension, so
  Finder shows `X.app` or `X.rtfd` as an app or a document: such a folder
  (extension conforming to `com.apple.package`) carries `com.apple.quarantine`
  like a file from the device, so Gatekeeper checks it (round 8b ruling). Such
  a folder and everything in it are read-only on the Mac (reading and listing
  only), since an app saving it would replace the whole folder; no folder may
  be renamed to such a name (round 9 ruling). Since round 10b its folders take
  new items on disk (so FileProvider can apply the device's deletions); the
  agent refuses every change in them, so a Mac app's replace-save leaves its
  copy, with an error, on the Mac only.
- **What a delete removes** (round 10 m3/m4). A delete passes everything it
  checked; the device side deletes only objects matching those by path, kind,
  size and date (a folder by kind), since no object ID crosses `DeviceSession`.
  Two gaps remain: an object replaced by one of the same kind, size and date
  passes, and libmtp keeps the size and date it first read for an object, so a
  file rewritten in place under the same object ID passes too.

## Anti-goals (failure even if it "works")

- Any telemetry, analytics, crash upload, account, licence key or nag.
- Finder beachballs because a device call blocks.
- Silently losing or truncating a file (partial uploads must never appear as
  complete files on either side).
- Fighting the user's system: no permanent killing of system daemons, no
  kernel extensions, no macFUSE.

## Constraints

- **Platform:** macOS 26 minimum, Apple silicon (arm64) only for v1 (Homebrew
  libmtp/libusb are arm64; universal comes later if wanted). Builds with
  Xcode 27.2 (installed at `/Applications/Xcode.app`; the active developer dir
  is the CLT, so build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  or have the owner run `sudo xcode-select -s`).
- **Modern Apple architecture (owner requirement):** Swift 6 language mode with
  strict concurrency; async/await and actors, no GCD callbacks or locks in new
  code; SwiftUI for all UI (`MenuBarExtra`, `Settings` scene) with the system's
  current (Liquid Glass) materials, SF Symbols, no custom chrome; Observation
  (`@Observable`), not Combine/`ObservableObject`; `SMAppService` for the login
  agent; Swift Testing (`@Test`), not XCTest, for unit tests; String Catalog;
  `os.Logger` for logging. Core logic in local Swift packages so it's testable
  without the app.
- **Signing:** Developer ID Application (team `X6JWYP43HG`) + notarization for
  release builds. The FileProvider extension and app group need a Developer ID
  provisioning profile with the App Groups capability — the owner creates the
  App ID / group / profile in the developer portal (builder supplies the exact
  identifiers). Local dev builds sign with the Apple Development identity.
- **Licensing of dependencies:** libmtp and libusb are LGPL-2.1 → link
  dynamically, ship the unmodified dylibs in `Contents/Frameworks`, include
  their licence texts and a source-offer note. MIT for our code.
- **Android 8+ (owner requirement).** Older MTP stacks vary more: some lack
  `MoveObject` or `CopyObject`, some lack 64-bit partial reads, and some
  enforce the 4 GB object limit through FAT32 SD cards. `MTPTransport` must
  find out what each device supports and fall back (copy+delete, whole-object
  reads), and must report a clear error when the target storage can't hold a
  file over 4 GB. Never truncate. No Android-version-specific code paths;
  decide by device capability.
- **The FileProvider extension is sandboxed and cannot own the USB device.**
  (Confirmed by MacDroid's own shipped layout: its FileProvider extension is
  sandboxed with only an app group, and does not link libmtp; the host app
  does.) Therefore the device is owned by a separate unsandboxed process and
  the extension is a thin client over IPC.
- **MTP is single-owner and sequential:** one process may hold the session;
  libmtp calls are blocking and not thread-safe per device.
- **macOS's `ptpcamerad`** (Image Capture service) and apps like Preview,
  Photos, Google Drive and Dropbox can claim the phone first, making libmtp's
  claim fail. This is the #1 support issue in OpenMTP's tracker. Must be
  handled (see Risks) — spiked before anything else is built.

## Architecture (owner-decided: Finder-native, Swift, MIT, transports pluggable)

```
Ferry.app (SwiftUI menu-bar app, LSUIElement)
 ├─ Contents/Library/LaunchAgents/…plist  → FerryAgent (unsandboxed)
 │     owns USB devices via DeviceTransport; vends XPC Mach service
 │     named with the app-group prefix; manages NSFileProviderDomains
 └─ Contents/PlugIns/FerryFileProvider.appex (sandboxed)
       NSFileProviderReplicatedExtension; every operation → XPC → agent
```

- **Agent** (registered with `SMAppService.agent`, MachServices in its plist):
  the only process touching hardware. Watches for devices, choosing candidates from
  the IOKit registry alone (an Apple device, or anything not MTP-shaped, is never
  opened or probed; an Android device without its MTP interface is shown as not
  sharing files), opens sessions,
  serialises calls per device inside an `actor`, adds/removes one
  `NSFileProviderDomain` per device storage, signals enumerators after its own
  writes. Survives the menu-bar app quitting.
- **Menu-bar app:** SwiftUI `MenuBarExtra` + `Settings`; talks to the agent over
  the same XPC interface for status/progress; registers the agent on first
  launch ("Open at login" toggle).
- **FileProvider extension:** maps FileProvider calls to XPC requests:
  enumerate, fetchContents (the extension creates the file in its domain's temporary
  directory and sends the agent an open descriptor; the agent downloads into a scratch file of
  its own and copies into that descriptor, so it never opens a path a client named), createItem
  (upload, the file likewise sent as a descriptor), modify (rename/move; content change =
  upload to a temp name, then swap: see "Write safety"), delete.
  Item identifiers are opaque, stable IDs assigned by the agent (see "Item identity").
- **Packages:**
  - `DeviceKit` — `DeviceTransport` protocol + value types (`DeviceInfo`,
    `StorageInfo`, `RemoteItem`, errors). No libmtp import.
  - `MTPTransport` — `DeviceTransport` over libmtp (C module map over the
    Homebrew headers for dev; bundled dylibs for release).
  - `FerryIPC` — the XPC protocol (Codable request/response or
    `NSXPCInterface`, builder's call) shared by agent, app, extension.
  - A `FakeTransport` in DeviceKit's test support for unit tests.

### Transports

`DeviceTransport` is the seam. Plan 2 shipped `MTPTransport`; Plan 2b adds ADB over USB
and Wi-Fi behind the same protocol without touching the extension. The protocol does not leak
MTP or ADB concepts (capabilities are queried, not assumed).

### ADB (amended 2026-11-18, Plan 2b)

**Engine (owner decision 2026-11-18).** Ferry talks to the standard adb server
(`127.0.0.1:5037`, adb's host protocol) and never bundles Google's `adb` binary, whose licence
does not allow it. Ferry finds an installed `adb` (Homebrew `android-platform-tools`,
Android Studio's `~/Library/Android/sdk/platform-tools`, `$ANDROID_HOME`) only to start the
server and to run `adb pair` / `adb connect`; everything else goes over the socket. When no
`adb` is found, MTP keeps working and the menu and setup guide show the one-line install. A
native Swift ADB engine (no install step) is a future-release row, not Plan 2b.

**One device, one Finder location, best method wins.** The agent sees a device through MTP, ADB
over USB, or ADB over Wi-Fi, and keys it by its serial (`ro.serialno` for ADB, the USB serial
for MTP: the same string on Android) so the Finder location and item identities stay the same
whichever method serves it. Preference: ADB over USB, then MTP over USB, then ADB over the
network (amended 2026-11-18 after a security review: a network device must never take over a
USB-attached unit's location on a matching serial alone; the network route serves a device only
while no USB route presents it). MTP is
never removed: it is the fallback whenever USB debugging is off, unauthorised, or `adb` is not
installed. Switching method mid-session is a session replacement in the hub, not a new domain.

**Storages.** ADB exposes the same user storages MTP does, not the whole filesystem: internal
shared storage (`/storage/emulated/0`) and each removable volume (`/storage/<UUID>`). Storage
keys become method-neutral (`internal`, `volume:<UUID>`), and MTP storages map onto them; where
an MTP storage cannot be matched it keeps its MTP key and is served by MTP only. Android's MTP
server sends no volume identifier, so an SD card over MTP keeps its description key, which every
card of a vendor shares, and is never mapped to an ADB volume (owner ruling 2026-11-18):
correctness over convenience, since a mapping applied over MTP alone could hand one card's
location, and its pending writes, to another card of the same size. An SD card therefore has
one Finder location per method.

**Protocol rules.** File I/O uses the sync service (`STAT`/`LIST`/`RECV`/`SEND`, with
`stat_v2`/`ls_v2` 64-bit variants when the device advertises them; on Android 8, where
`ls_v2` is absent, listing sizes come from `STA2`). Rename, move, folder creation and delete
run as shell commands with arguments quoted by Ferry, never interpolated; results are checked
with exit status (`shell_v2`) or an explicit status echo. The same `SafeWriter`, expecting
checks and conflict rules as MTP apply.

**Method shown.** The menu names each device's method ("USB · ADB", "Wi-Fi · ADB",
"USB · File transfer") and, for MTP, how to get ADB.

**Wireless.** Android 11+: pair with the pairing code (`adb pair`) and connect via mDNS
discovery. Android 8–10: switch a USB-connected device to TCP (`tcpip 5555`) and connect by
address. Ferry remembers paired devices and reconnects when they are seen; it never scans
networks.

**Tools (ADB only).** Screenshot, screen recording, APK install (top priority), logcat viewer,
shell (opened in Terminal), port forwarding, device info. Screenshots and recordings save where
macOS saves its own screenshots.

**Finder Sync.** A Finder Sync extension adds "Send to <device>" for Mac files (into the
device's Download folder) and "Install on <device>" for `.apk` files, plus a toolbar button.
It talks only to the agent.

### Change detection

Replicated FileProvider honours signals only on the working set. The agent keeps a per-domain
change log (anchored, in memory, bounded) fed by its own mutations and by listing diffs, and
signals the working set; the extension's working-set enumerator reports changes since an
anchor. An anchor from an earlier agent process is reported expired, so the system
re-enumerates. Phone-side changes surface on their own (amended 2026-11-19, owner request after
the live run): over ADB the agent watches the folders it has listed with the device's `inotifyd`
and re-lists a folder when it reports any event (events are treated as hints, since shared
storage reports them incompletely); over MTP it reads the device's object events; and while a
device is connected the agent re-lists its most recently listed folders every 30 s (at most 32
folders, skipped while a transfer is running, paused while the Mac sleeps), signalling only
when a listing differs. Menu "Refresh" stays as the manual re-list.

## Item identity (amended 2026-11-17)

FileProvider identifies an item by its `itemIdentifier` across renames and moves: a remote
reparent keeps the identifier and changes `parentItemIdentifier`, and a `modifyItem` that
returns a *different* identifier tells the system to merge into that item and delete the
other one from disk (`NSFileProviderReplicatedExtension.h`, "merge" and "reparented"
passages). Identifiers may also be written to system logs (`NSFileProviderItem.h`), so they
must not contain file names. Therefore:

- The agent assigns each item an opaque random identifier on first sight and keeps a
  per-domain table identifier ↔ storage-relative path, persisted in the agent's own
  Application Support (not the app-group container, which the sandboxed extension can write).
- Rename and move update the table for the item and its subtree; delete and listings that
  drop a child prune it. An item replaced on the phone by one of a different kind (file ↔ folder)
  gets a new identifier; a file replaced by a file of the same name keeps its identifier and
  shows as a content change (its size/date version changes).
- FerryIPC speaks identifiers, not paths; the root is `NSFileProviderItemIdentifier.rootContainer`.

## Testing and quality bar

- Swift Testing unit tests for DeviceKit, IPC encoding, and the
  FileProvider→IPC mapping against `FakeTransport`, including disconnect
  mid-transfer and >4 GB size handling (sizes as `UInt64`/`Int64` everywhere).
- `MTPTransport` gets an integration test target that runs only when a device
  is attached (skipped otherwise).
- Manual device checklist (the owner's phones plus an Android 8 or 9 device)
  in `docs/TESTING.md`.
- `make lint` (SwiftLint), `make fmt-check` (swift-format), `make test`,
  `make build`; zero warnings; GitHub Actions on macOS runners runs lint+test.
- XcodeGen `project.yml` generates the Xcode project (project file not
  committed).

## Risks — spike first

1. **ptpcamerad / Image Capture claim conflict.** Spike: can the agent claim a
   phone while `ptpcamerad` is running; if not, what is the least invasive
   fix (detect + guide the user; stop it only while we hold the device; the
   `com.apple.ImageCapture` auto-open setting). Outcome decides the setup UX.
2. **FileProvider for a local device.** Confirm a replicated extension behaves
   well for a removable, non-cloud source (domain add/remove on plug/unplug,
   eviction, large files). MacDroid shipping this way says it's viable.
3. **Sandboxed extension → agent XPC.** Confirm the app-group-prefixed Mach
   service is reachable from the sandboxed extension.

## Owner decisions (2026-11-17)

- **Distribution is direct download only, now and later:** a signed,
  notarized DMG on GitHub Releases, plus a Homebrew cask. It will never go on
  the Mac App Store, so the unsandboxed agent stays.
- **Phone-grab conflict (Risk 1): "whatever works, even admin."** Use the
  least invasive approach the spike proves works, in this order:
  1. claim the phone with nothing extra;
  2. stop `ptpcamerad` as the user only while we hold a device;
  3. a privileged helper registered with `SMAppService.daemon`, approved once
     by the user, that does only that pause and resume.

  Whichever step is used, the service must come back when the phone is
  released. Never disable it permanently.

## Decisions made by the designer (owner to check)

- **Agent lifecycle.** The menu-bar app registers the agent on first launch.
  The agent then runs while registered, whether or not the menu-bar app is
  open. Settings has "Remove Ferry", which removes all domains (keeping unsent
  file contents, as Eject does) and then unregisters the agent. A Mac where the
  app was never launched shows nothing.
- **Write safety.** An upload goes to a hidden temp name
  (`.ferry-partial-<uuid>`) and is renamed when it completes. On failure
  the agent deletes the partial object. Leftover objects with that prefix
  (from a crash or an unplug) are hidden from listings and deleted whenever
  their folder is listed. This is lazy because walking a whole phone at
  connect can take minutes.
- **Replacing a file.** A content modify uploads the new data to a temp name,
  renames the old object to a hidden `.ferry-backup-<uuid>-<original name>`,
  renames the temp into place, and only then deletes the backup. If the temp
  cannot be renamed, the backup is renamed back, so a failure never loses both
  versions. (A name too long to fit is set aside as `.ferry-backup-<uuid>`.)
  Listings hide backups. A backup this session made, or one in a folder with a
  write in flight, is left alone. Any other backup (the agent stopped, or the
  device was unplugged between the two renames) is resolved when its folder is
  listed:
  - its original name is free: the backup is renamed back (restored);
  - a complete file holds the name, read back as a file: the backup is deleted;
  - anything else (a folder at the name, no readable name): it is kept.
  A backup is never deleted blindly. Only a device that cannot rename at all
  falls back to delete-then-upload, and any failure is surfaced as an error,
  never hidden. Capabilities are queried per device through `DeviceTransport`.
- **Item identity.** One domain per device serial + storage, so it persists
  across reconnects. Its identifier is the SHA-256 (hex) of "<serial>|<storage key>",
  never parsed back, so the serial is not in FileProvider's logs or paths. Item
  identifiers are the agent's opaque random IDs (see "Item identity" above), kept
  across reconnects and agent restarts; MTP object IDs are a per-session cache inside
  the agent and never leave it. When a device is unplugged, its domain is
  disconnected (shown as unavailable), not removed. "Eject" in the menu removes
  it, keeping any changes not yet sent to the device (the system moves them aside
  and the menu says where). Removing a location, by Eject or "Remove Ferry", keeps
  unsent file contents only: pending deletes and renames are dropped, which errs
  on the safe side (the device keeps the file under its old name).
- **Hardware bar for v1.** Android 8 (Oreo) and newer (owner decision; see
  Constraints). Works on the owner's phones plus at least one Android 8 or 9
  device.
  `docs/TESTING.md` lists the steps. Locked phone shows an "Unlock your phone"
  state, not an error.
- **Multiple devices.** Any number of devices at once, one actor each. Domain
  names are "<Model>" or "<Model> (<last 4 of serial>)" when two match, with
  " – SD card" for secondary storage.
- **Release dylibs.** libusb and libmtp are built from pinned source tarballs
  in CI, with an `@rpath` install name and the same minimum macOS as the app.
  Homebrew is used only for local development.

## Left to the builder

Bundle IDs, app-group string, XPC interface style, folder layout, exact
SwiftUI layout of the menu, how progress is reported, libmtp module-map
mechanics, CI details.
