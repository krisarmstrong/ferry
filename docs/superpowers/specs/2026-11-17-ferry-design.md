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

## Non-goals (v1)

- ADB mode and Wi-Fi mode — **designed for, not built** (see Transports).
- Finder badges / FinderSync extension.
- "Keep offline" pinning beyond what the system provides.
- Auto-update (Sparkle), localisation beyond English (but strings go in a
  String Catalog from day one), Intel builds.
- Photo/camera (PTP) import — Image Capture already does that.

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
  the only process touching hardware. Watches for devices, opens sessions,
  serialises calls per device inside an `actor`, adds/removes one
  `NSFileProviderDomain` per device storage, signals enumerators after its own
  writes. Survives the menu-bar app quitting.
- **Menu-bar app:** SwiftUI `MenuBarExtra` + `Settings`; talks to the agent over
  the same XPC interface for status/progress; registers the agent on first
  launch ("Open at login" toggle).
- **FileProvider extension:** maps FileProvider calls to XPC requests:
  enumerate, fetchContents (agent downloads to a file in the app-group
  container, extension hands it to the system), createItem (upload), modify
  (rename/move; content change = upload to temp name then swap), delete.
  Item identifier = `"<storageID>/<objectID>"`; root = storage root.
- **Packages:**
  - `DeviceKit` — `DeviceTransport` protocol + value types (`DeviceInfo`,
    `StorageInfo`, `RemoteItem`, errors). No libmtp import.
  - `MTPTransport` — `DeviceTransport` over libmtp (C module map over the
    Homebrew headers for dev; bundled dylibs for release).
  - `FerryIPC` — the XPC protocol (Codable request/response or
    `NSXPCInterface`, builder's call) shared by agent, app, extension.
  - A `FakeTransport` in DeviceKit's test support for unit tests.

### Transports (ADB / Wi-Fi later)

`DeviceTransport` is the seam. v1 ships `MTPTransport` only. Future
`ADBTransport` (adb sync protocol; requires bundling or locating `adb`) and a
Wi-Fi transport plug in behind the same protocol without touching the
extension. The protocol must not leak MTP concepts (object IDs are opaque
strings; capabilities such as "supports move" are queried, not assumed).

### Change detection

MTP has no reliable change events. v1: re-enumerate on folder open and on the
menu "Refresh"; after its own writes the agent signals the working set. No
polling loops.

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
  open. Settings has "Remove Ferry", which removes all domains and then
  unregisters the agent. A Mac where the app was never launched shows nothing.
- **Write safety.** An upload goes to a hidden temp name
  (`.ferry-partial-<uuid>`) and is renamed when it completes. On failure
  the agent deletes the partial object. Leftover objects with that prefix
  (from a crash or an unplug) are hidden from listings and deleted whenever
  their folder is listed. This is lazy because walking a whole phone at
  connect can take minutes. A content modify uploads the new data to a
  temp name, deletes the old object, then renames. A device that cannot rename
  falls back to delete-then-upload, and any failure is surfaced as an error,
  never hidden. Capabilities are queried per device through `DeviceTransport`.
- **Item identity.** One domain per device serial + storage description, so it
  persists across reconnects. Item identifiers are storage-relative paths,
  which survive reconnects. MTP object IDs are a per-session cache inside the
  agent and never leave it. When a device is unplugged, its domain is
  disconnected (shown as unavailable), not removed. "Eject" in the menu removes
  it.
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
