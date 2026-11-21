# Ferry V1 readiness

Where Ferry stands against a 1.0 release, as of v0.4.0 (2026-11-20). For each area: what is
done, how it is verified, and what is still open. The last section lists the checks only the
owner can run, on real devices and Macs. Open items name their workstream (W1–W5 of the V1
plan) where one owns them.

Legend: **Done** is in `main` and verified as stated. **Open** must land before 1.0.
**Later** may ship after 1.0.

## Summary

| Area | State | Open before 1.0 |
|---|---|---|
| Security | Strong | Device data in public log lines; release job supply chain |
| Concurrency | Not re-audited | Actor review; bound in-flight requests; cancel enumerations |
| Performance | Needs work | Item table writes and paging on large devices; background relisting |
| Accessibility | Good in code | Live VoiceOver and keyboard pass; Help link labels |
| Localization | English only, mostly ready | Plurals, two hard-coded English strings |
| UX and copy | Good | Raw error text in a few failures; first-run (W4) |
| Docs and legal | Mostly done | Sparkle licence notice; LGPL source with each release; privacy wording; TESTING.md |
| Packaging | Done | macOS 26 never tested live |

## Security

**Done**
- XPC: the app, the FileProvider extension and the Finder extension each connect in their own
  role, and each role may send only its own requests. Both ends require the other to be signed
  by Ferry's team with the expected identifier, checked by XPC on every message.
  *Verified:* `AgentXPC.swift`, `FerryIdentity.swift`, `FinderSyncRoleTests` and
  `MessagesTests` (what each role may send), `make check-app` (every part records the same
  team).
- Files from a device: names are validated as a single path component; packages and links are
  refused on the way to the device; files from the device are quarantined like downloads.
  *Verified:* `RemotePath`, `ItemTemplate`, `ProviderItem`, `AgentPackageTests`, and
  `make check-app` checks the quarantine attribute is declared.
- Finder's Send to: opens with `O_NOFOLLOW` and sends only regular files; the helper checks the
  descriptor again.
- adb download: HTTPS only, Google hosts only (redirects included), size cap while streaming,
  pinned size and SHA-256 before the archive is read, a strict zip reader, only `adb` and its
  notice kept, Google's Developer ID signature checked offline before first use, into a private
  folder. *Verified:* `PlatformToolsFetcherTests`, `ZipArchiveTests`, `HTTPSDownloadTests`,
  `CodeSignatureTests`;
  `scripts/adb-fetch-live-check.sh` against the live archive.
- Updates: Sparkle with a signed feed, EdDSA-signed archives, verification before extraction,
  no system profiling. The release workflow checks the appcast against the public key built into
  the app before publishing. *Verified:* `release.yml` "Check the appcast" step; live update
  from 0.2.1 to 0.3.0 on the owner's Mac.
- Release workflow: actions and tools pinned by hash; signing only for release-please's own
  draft, its tag and its commit on `main`; secrets only in the protected `release` environment.
  Hardened runtime, Developer ID, secure timestamp and no `get-task-allow` on every executable.
  *Verified:* `scripts/check-release.sh` in CI (`make release SIGN=adhoc`) and in every release.
- Secrets: none in the repo; history scanned before the repo went public.

**Open**
- Several log lines print transport errors as public text, and those errors can carry a device
  serial, a path on the device or a network address. Log the error kind publicly and its details
  privately, and add a test that keeps it that way. (W5 finding M1)
- The release job installs an unpinned Homebrew package that later runs while the signing
  identity is available. Pin it by hash or drop the dependency. (M11)
- Home-folder paths in a few public error logs. (L4, Later)
- Secret scanning in CI. (L13, Later)

## Concurrency

**Done**
- Swift 6 with complete strict concurrency; device work is serialised per device; transfers
  cancel when their client goes away (except the Finder extension's fire-and-forget sends);
  logcat and listings are bounded. *Verified:* CI's lint and test run on every PR, and the
  per-task reviews during development. The V1 audit did not re-read the actors (`DeviceHub`,
  `DomainController`, `WirelessADB`) for reentrancy.

**Open**
- A reentrancy and cancellation review of the three main actors.
- Bound the number of requests a client may have in flight. (L1)
- Cancel FileProvider enumerations when Finder invalidates them. (L2)
- Injected clocks for the time-bound ADB suites, so CI can run tests in parallel again. (W3)

## Performance

**Done**
- Transfers measured on a network tester over USB: about 37 MB/s upload and 36 MB/s download
  through Finder, roughly 90% of raw adb. The menu polls only while it is open.

**Open**
- The helper rewrites a device's whole item table on every change, and pages the working set
  by sorting the whole table each time, so both cost more as a device's file count grows. A
  debug-build probe put one change on a 10,000-item table at a few tenths of a second; a
  release-build measurement is still needed. Coalesce the writes and keep a sorted index; add a
  10,000-item performance test. (H1, M10)
- Folder listings reach Finder as one batch; page them. (M9)
- While a device is connected, up to 32 folders are listed again every 30 s even when no Finder
  window shows them. Relist only what Finder is showing, with back-off. (M3)
- The Wi-Fi rediscovery poll runs even when no device is remembered. (L3, Later)

## Accessibility

**Done (by code reading)**
- Menu rows are buttons with text labels; decorative symbols are hidden; expanding rows read
  "<name>, <summary>" with Expanded or Collapsed; the Open at Login row reads as a switch;
  form fields and the log window's controls have labels; dialogs have default and cancel keys.

**Open**
- Help links all read "Help"; name the problem. (L5)
- A row's warning colour is invisible to VoiceOver; say it. (L6)
- Arrow-key movement between menu rows. (L7)
- Text and windows that follow larger text sizes. (L8)
- Increase Contrast, Reduce Transparency and dark-mode contrast pass. (W1)
- A live VoiceOver and Full Keyboard Access pass (owner check below).

## Localization

**Done**
- User-facing text lives in String Catalogs, one per module; sizes use the system byte-count
  formatter; device-supplied text is escaped before display.

**Open (Later unless a translation ships with 1.0)**
- Plural variants for counted messages; the " – SD card" suffix of Finder location names and the
  capture file names are hard-coded English; one message joins two sentences. (L14)

## UX and copy

**Done**
- Every problem shown in the menu has a Help entry, enforced by `HelpMessageCoverageTests`; Help is
  searchable and the user guide is generated from it (a test fails if they differ).

**Open**
- A few failures still show raw technical text ("Error: …") or a generic "The device reported an
  error." with no next step. Give each one plain words, a next step and a Help link. (M2)
- Remove Ferry leaves Ferry's data (the fetched adb, remembered devices, file listings) and may
  leave its adb server running; offer to delete the data and document what stays. (M8)
- Automatic updates have no off switch; add one to the menu. (M4)
- One message says "agent" where everything else says "helper". (L9)
- First-run onboarding and empty states. (W4)
- A purpose string for the Documents access prompt (L10); Local Network access (W2, PR #14).

## Docs and legal

**Done**
- README, user guide (generated from in-app Help), RELEASING, privacy section in Help.
- libmtp and libusb: built unmodified from pinned release tarballs, linked dynamically, their
  LGPL-2.1 texts and the exact tarball URLs and SHA-256s in `Contents/Resources/Licenses`,
  checked by `check-release.sh`.
- Google's Android SDK License: shown and accepted before any download, acceptance recorded,
  the accepted text bundled; Ferry never redistributes Google's binaries.

**Open**
- Sparkle's MIT licence (and the notices it carries for its own dependencies) is not in the app
  or the README. Ship it in `Licenses`, check it in `check-release.sh`, and add an
  Acknowledgements topic to Help. (M5)
- Attach the exact libusb and libmtp source tarballs to each GitHub release, so the source is
  offered from the same place as the binary. (M6)
- Privacy wording: GitHub and Google see the Mac's IP address and Ferry's version. (L11)
- TESTING.md predates ADB and lists a Settings window Ferry no longer has; replace its manual
  checklist with the owner checks below. (L12)

## Packaging

**Done**
- Signed with Developer ID, hardened runtime, notarized and stapled: the app and the DMG. The
  Sparkle archive and the appcast are attached to the GitHub release, which is published only
  after every check passes. Apple silicon only, as the README states.
  *Verified:* releases 0.2.1 through 0.4.0 built and published by the workflow; 0.4.0 installed
  from the DMG on the owner's Mac.

**Open**
- macOS 26 is the stated minimum, but Ferry has only been run on macOS 27. Test on 26 or raise
  the minimum. (M7)
- A designed DMG background. (W1)

## Owner-only checks

These need real hardware, a real Mac session or a person at the keyboard. Record the build and
the result for each.

1. **Clean install on macOS 26.x** from the release DMG: open, turn on in Finder, connect a phone
   over USB, browse, copy both ways.
2. **Each supported tester** over USB with file transfer, then with USB debugging, then over
   Wi-Fi: browse, copy a 1 GB file both ways, compare SHA-256.
3. **Large folder:** a folder of 10,000 or more files on a real device: time to open in Finder,
   copy 500 files in, delete a folder, and the helper's CPU and memory meanwhile.
4. **Unplug mid-copy and replug** (never run so far): the menu shows the waiting changes, and the
   copy finishes after replugging.
5. **Battery:** a device attached for an hour with Finder closed; `powermetrics` energy impact of
   FerryAgent and the adb server.
6. **Start-up and menu-open time** on a release build (Instruments, Time Profiler), and helper
   memory after an 8-hour session with a device attached.
7. **VoiceOver:** every menu row, the setup guide, Help, the licence window, the log and port
   forwarding windows. **Full Keyboard Access:** reach every control. **Increase Contrast**,
   **Reduce Transparency** and the largest text size: nothing clipped or unreadable.
8. **Updates:** from the previous release by Sparkle, on an admin and on a standard account;
   **Check for Updates…** when up to date and when offline.
9. **Local Network:** the first Wi-Fi connect shows macOS's prompt, and denying it shows Ferry's
   explanation (after PR #14).
10. **Get Android Platform Tools** on a Mac without adb, then offline (clear message), then
    after an update that pins a newer adb.
11. **Remove Ferry**, then check what remains: Finder locations, the login item, the helper, an
    adb server, and files under `~/Library/Application Support/Ferry` and
    `~/Library/Application Support/io.github.krisarmstrong.ferry.agent` (both deleted after #33).
12. **Upgrade over a developer build** (signing identity change): the helper restarts without a
    manual `launchctl` step (W2). The opposite direction, a developer build over Developer ID
    0.4.0, was proven on the integration branch (see the V1 fix report); this check covers
    the release build going over a developer one.
13. **Pair by code** from the menu (`host:pair`): pair a device with Wi-Fi debugging, confirm it
    connects and is remembered. Never exercised on hardware: the integration smoke test ran with
    the screen locked.
14. **Forget** that device from the menu (`host:disconnect`, whose failure path is new): the
    menu drops it, and `adb devices` no longer lists it.
15. **Create while the device is refused:** with the device attached but refusing Ferry
    (unauthorized, or the adb server cut off from the network), create a small file in the
    device's Finder location. Record what Finder shows and what reaches the device.
16. **The stray duplicate after a refused create:** after check 15, and again once the device
    is reachable, look for a local-only copy named like `name 2.txt` beside the real file. The
    integration smoke test left one (`integration-small 2.txt`) that never reached the device,
    which could leave a user believing a file was sent. Note whether it appears, whether it
    ever syncs, and whether Finder marks it as not uploaded.

## W5 fixes (2026-11-20)

The W5 findings were fixed in one PR per group. All are open against `main` and not yet
merged; verify each against `main` once it lands.

| Findings | PR |
|---|---|
| H1, M10, M9, L2 (item table journal and index, paged listings, enumerator cancel) | #25 |
| M1, L4 (private error logs; default-deny `LogPrivacyTests`) | #26 |
| M2, L5, L9 (helper wording), L10, L11 (stacked on #25) | #29 |
| M3 (relist only while in use) | #30 |
| M5, M6 (Sparkle licence, Acknowledgements, LGPL tarballs on each release) | #31 |
| M4 (Install Updates Automatically) | #32 |
| M8 (Remove Ferry deletes data, stops only Ferry's adb) | #33 |

**Left, with the reason**
- M7, macOS 26 never run live: owner check 1; no macOS 26 Mac or VM here.
- M11, pkgconf in the release job: W3 owns `release.yml` hardening.
- L1, no in-flight cap per XPC connection: needs back-pressure design in `AgentXPC` that
  FileProvider's own retry tolerates; device work is already serialised (`DeviceTurns`), so the
  cost is descriptors and tasks, not device load. Later.
- L3, `adb devices` every 30 s with nothing remembered: `WirelessADB+Connecting` is W2's and
  `ferry-localnet`'s area, both with open PRs there (#19, #14); a one-line early return to add
  after they land.
- L6, L7, L8 (severity only in a tinted symbol, no arrow keys in the menu, fixed sizes): menu
  and window layout are W1's (#22); owner check 7 covers them live.
- L9, "unit", "tester" and "device" mixed in steps: the guide steps name NetAlly models on
  purpose (`UserGuideMirrorTests` limits where); a copy pass with W4's first-run work.
- L12: done here (TESTING.md points to the V1 checklist above).
- L13, secret scanning in CI: `ci.yml` is being changed by W3 (#24); add a pinned gitleaks step
  after it lands, to avoid two PRs editing the same jobs.
- L14, plurals: the counted strings ("Couldn’t send %lld files to %@" and the like) are only
  shown for two or more items, so English needs no singular; a translation adds its own plural
  forms in the String Catalog. The SD card suffix (`DomainNaming.swift`), capture file names
  (`CaptureFiles.swift`) and the sentence join in `FinderSender.swift` stay until a translation
  is planned.
- L15, Sparkle gentle reminders: needs a user-driver delegate and an "Update ready" menu row,
  testable only with a live update; owner check 8 first.
- I1–I5: informational, no action. I5: the new item-table journal is created 0600; the snapshot
  keeps the default mode under `~/Library` (0700).

## Audit trail

The W5 audit of v0.4.0 found 0 critical, 1 high, 11 medium, 15 low and 5 informational items;
the finding IDs above (H1, M1–M11, L1–L15) refer to that audit. The audit changed no code. It
did not launch Ferry, so start-up, memory and live accessibility are the owner checks above.
