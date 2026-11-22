# Ferry V1 readiness

Where Ferry stands against a 1.0 release, as of `main` at e8a301e (release 0.6.0, 2026-11-22).
For each area: what is done, how it is verified, and what is still open. The last section lists
the checks only the owner can run, on real devices and Macs.

Every item below was checked against the code and tests on `main`, not against PR titles. The
W5 audit's fix PRs (#25, #26, #29–#33) and the onboarding PR (#37) were closed or merged into
`v1/integration` and reached `main` through #36; #38, #41 and #42 followed on `main`.

Legend: **Done** is in `main` and verified as stated. **Open** must land before 1.0.
**Later** may ship after 1.0.

## Summary

| Area | State | Open before 1.0 |
|---|---|---|
| Security | Strong | Nothing; secret scanning in CI is Later |
| Concurrency | Strong in tests, not re-audited | Reentrancy review of the three main actors |
| Performance | Done in code | Release-build and real-device numbers (owner checks 3, 5, 6) |
| Accessibility | Good in code | Warning severity for VoiceOver; arrow keys; larger text; live pass |
| Localization | English; Spanish in progress | L14 in progress (Spanish) |
| UX and copy | Good | One local-file failure reads as a device failure; the stray duplicate after a refused create |
| Docs and legal | Done | Nothing |
| Packaging | Done | macOS 26 never run live; DMG window never checked on screen |

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
  `CodeSignatureTests`; `scripts/adb-fetch-live-check.sh` against the live archive.
- Updates: Sparkle with a signed feed, EdDSA-signed archives, verification before extraction,
  no system profiling. The release workflow checks the appcast against the public key built into
  the app before publishing. *Verified:* `release.yml` "Check the appcast" step; live update
  from 0.2.1 to 0.3.0 on the owner's Mac.
- Release workflow: actions and tools pinned by hash; signing only for release-please's own
  draft, its tag and its commit on `main`; secrets only in the protected `release` environment.
  Hardened runtime, Developer ID, secure timestamp and no `get-task-allow` on every executable.
  The disk image is signed only if it holds exactly the stapled app.
  *Verified:* `scripts/check-release.sh` in CI (`make release SIGN=adhoc`) and in every release;
  `scripts/check-dmg-contents.sh`, with `scripts/check-dmg-contents-test.sh` in CI showing it
  refuse a changed byte and an extra entry.
- Private logging (M1, L4): every value a log line interpolates states its privacy, and a public
  one must be on a reviewed allow-list of counts, sizes, status codes and transport names. Errors,
  serials, paths, addresses and home folders are private. *Verified:* `LogPrivacyTests`
  (`everyPublicInterpolationIsReviewed`, `everyLoggedValueSaysItsPrivacy`) over
  `Tests/LogPrivacyAllowList.txt`.
- No unpinned tool with the signing identity available (M11): Homebrew is gone from the release
  job; XcodeGen and Sparkle's tools are downloaded and checked against pinned SHA-256s, and
  pkgconf is built from a pinned, checked tarball (`scripts/build-pkgconf.sh`). The build step
  fails unless `pkg-config` is that build. What still runs with the identity usable, each on a
  pin, is an accepted residual named in `docs/RELEASING.md`. *Verified:* `release.yml`
  "Install XcodeGen, pkgconf and Sparkle's tools" and "Build and sign" steps.
- Secrets: none in the repo; history scanned before the repo went public, and on every change
  since (L13). *Verified:* `ci.yml` job `secrets` runs gitleaks 8.30.1, pinned by SHA-256, over
  the whole history; one prose false positive is fingerprinted in `.gitleaksignore`.

## Concurrency

**Done**
- Swift 6 with complete strict concurrency; device work is serialised per device; transfers
  cancel when their client goes away (except the Finder extension's fire-and-forget sends);
  logcat and listings are bounded. *Verified:* CI's lint and test run on every PR;
  `AgentCancelTests`.
- FileProvider enumerations are cancelled when Finder invalidates them (L2): every enumeration
  runs as a task the enumerator tracks, and `invalidate()` cancels them all
  (`Apps/FerryProvider/Enumerator.swift`, `invalidate` and `track`).
- Injected clocks for the time-bound ADB suites (W3): the ADB transport, server keeper, wake,
  wireless and logcat suites run on `ManualClock`, and CI runs the tests in parallel again
  (`make test` in `ci.yml`, no `--no-parallel`). *Verified:* `ADBServerKeeperTests`,
  `ADBTransportTimeoutTests`, `ADBWirelessLimitTests`, `ChangeWatchTests`.
- The app recovers an agent launchd will not spawn after a signing-identity change: it restarts
  the agent, and boots the job out once if no agent process appears. *Verified:*
  `AppModelAgentSpawnTests`; live, a team-signed build over Developer ID 0.4.0 restarted its
  agent by itself (the bootout fallback is covered by tests only).

**Open**
- A reentrancy and cancellation review of `DeviceHub`, `DomainController` and `WirelessADB`.
  No audit has re-read them for state that changes across an `await`; only the session gate's
  non-reentrancy is documented (`OperationGate.swift`).

**Done**
- A client may have at most 128 requests in flight per connection (L1); the next is refused with a
  reply, never dropped. *Verified:* `AgentListenerDelegate.maxInFlightPerConnection`,
  `AgentInFlightCapTests`.

## Performance

**Done**
- Transfers measured on a network tester over USB: about 37 MB/s upload and 36 MB/s download
  through Finder, roughly 90% of raw adb. The menu polls only while it is open.
- Item table (H1, M10): changes are appended to a journal and folded into a snapshot about once
  per table's worth of changes; the working set is paged by an identifier cursor over a kept
  order, not a sort per page (`ItemTable.swift`, `workingSet(after:size:)`). *Verified:*
  `ItemTableBenchmarkTests` on 10,000 and 40,000 items, with an upper bound per operation on the
  larger table; release numbers by the command in `docs/TESTING.md`.
- Folder listings reach Finder a page at a time (M9): `AgentService+Listing.swift`,
  `FolderPages`. *Verified:* `FolderPagesTests`.
- The 30 s relisting runs only while a Ferry location on the device is in use (M3), and stops
  after about 10 minutes without a request (`ChangeWatch.swift`, `idlePasses`). *Verified:*
  `ChangeWatchIdleTests` (`relistingStopsOnceNothingUsesTheDevice`, `aRequestResumesRelisting`).

**Later**
- The Wi-Fi rediscovery poll runs `adb devices` every 30 s even when no device is remembered:
  `offerFromMDNS()` lists adb's devices before it checks for remembered ones
  (`WirelessADB+Connecting.swift`, `pollMDNS` and `offerFromMDNS`). Return early when nothing is
  remembered. (L3)

## Accessibility

**Done (by code reading and snapshot tests)**
- Menu rows are buttons with text labels; decorative symbols are hidden; expanding rows read
  "<name>, <summary>" with Expanded or Collapsed; the Open at Login row reads as a switch;
  form fields and the log window's controls have labels; dialogs have default and cancel keys.
- Help links name their problem (L5): VoiceOver reads "Help:" and the problem's words, or the
  topic's title (`MenuNotice.swift`, `HelpLinkButton.label`). *Verified:* `HelpLinkTests`,
  `HelpNavigatorTests`.
- Increase Contrast and dark mode: device tiles and row symbols have pressed and
  increased-contrast states. *Verified:* `MenuSnapshotTests` (`theMenuDraws` in light, dark and
  both increased-contrast looks; `theDeviceTilesDraw`), `HelpSnapshotTests` in light and dark.
  Ferry uses no translucent materials, so Reduce Transparency changes nothing it draws.

**Open**
- A status row's warning is shown only by a yellow symbol, which is hidden from VoiceOver
  (`StatusRow` in `MenuRow.swift`; used by `GetADBRow.swift` and the "Ferry was updated" row in
  `MenuContent.swift`). Say the severity in the row's label. (L6)
- No arrow-key movement between menu rows: the menu has no `onMoveCommand` or focus handling
  (`MenuContent.swift`, `MenuRow.swift`). (L7)
- Fixed sizes: the menu is 320 pt wide (`MenuContent.swift`), the welcome 400 pt
  (`WelcomeView.swift`), the setup guide 460 pt (`SetupGuide.swift`), the licence window
  560 × 520 (`PlatformToolsLicenseView.swift`), and the row symbols a fixed 12 pt
  (`MenuRow.swift`). Let text and windows follow larger text sizes. (L8)
- A live VoiceOver and Full Keyboard Access pass (owner check 7).

## Localization

**Done**
- User-facing text lives in String Catalogs, one per module; sizes use the system byte-count
  formatter; device-supplied text is escaped before display.

**In progress (Spanish)**
- A Spanish translation, plural variants, the hard-coded " – SD card" suffix
  (`DomainNaming.swift`), capture file names (`CaptureFiles.swift`) and the joined sentence in
  `FinderSender.swift`. (L14)

## UX and copy

**Done**
- Every problem shown in the menu has a Help entry, enforced by `HelpMessageCoverageTests`; Help is
  searchable and the user guide is generated from it (a test fails if they differ).
- Plain words and a next step for every failure (M2): `TransportError` maps case by case, with no
  `default`, to a message and a Help key, and the agent's developer detail goes to the log only
  (`FerryText/PresentationText.swift`). Tool and Wi-Fi failures do the same; where the device or
  adb wrote a reason (an install refusal, a recording failure, an adb refusal, a failed log save)
  it follows the plain sentence and next step, escaped, in brackets.
- Remove Ferry (M8): once the helper has stopped, Ferry moves its two Application Support folders
  to the Trash, keeps a folder holding changes the system saved, stops only Ferry's own adb
  server and leaves an adb the user installed alone (`FerryDataRemoval.swift`). *Verified:*
  `FerryDataRemovalTests` (`ferrysDataGoesToTheTrash`, `nothingGoesUntilTheAgentHasExited`,
  `onlyFerrysAdbServerIsStopped`, `aRecycledPIDIsNotSignalled`,
  `aFolderHoldingSavedChangesIsKept`).
- Automatic updates (M4): closed by the owner's decision of 2026-11-21. Updates are always checked
  daily, downloaded in the background and installed when Ferry quits; there is no menu toggle, and
  a choice an earlier version saved does not turn them off (`Apps/Ferry/SparkleUpdates.swift`).
  *Verified:* `UpdateConsentTests`.
- One word for the background process (L9): user-facing text says "helper"; no catalog string
  or Help entry says "agent". The guide names NetAlly models and "the unit" on purpose in model
  steps (`UserGuideMirrorTests` limits where).
- First-run onboarding and empty states (W4, #37): a welcome on first run with steps that follow
  the status, and the setup guide offered after 10 s with no device (`WelcomeView.swift`,
  `AppModel+Welcome.swift`, `AppModel+EmptyState.swift`). *Verified:* `AppModelWelcomeTests`,
  `WelcomeCheckTests`, `WelcomeSnapshotTests`.
- Purpose strings: Documents (L10) and Local Network, in the app and the helper
  (`Apps/Ferry/Info.plist`, `Apps/FerryAgent/Info.plist`); a denied Local Network shows Ferry's
  explanation (#14).

**Open**
- Install App… names a local-file failure as a device one: when the chosen `.apk` cannot be
  opened, `AppModel+Tools.swift` wraps the error as `.io`, which reads "Ferry couldn't finish
  this. Try again; if it keeps failing, reconnect the device or reopen Ferry." Give it its own
  message. (M2, residual)
- A create while the device refuses Ferry left a local-only `name 2.txt` beside the real file
  that never reached the device (integration smoke test). Reproduce on hardware (owner checks 15
  and 16), then fix so Finder never shows a copy as sent when it was not.

**Later**
- Sparkle's gentle reminders and an "Update ready" row (L15). Updates install when Ferry quits,
  and a menu-bar app at login rarely quits, so an update can wait for days. Needs a user-driver
  delegate in `SparkleUpdates.swift` and a menu row; owner check 8 first.

## Docs and legal

**Done**
- README, user guide (generated from in-app Help), RELEASING, privacy section in Help.
- libmtp and libusb: built unmodified from pinned release tarballs, linked dynamically, their
  LGPL-2.1 texts and the exact tarball URLs and SHA-256s in `Contents/Resources/Licenses`,
  checked by `check-release.sh`.
- LGPL source with each release (M6): the release workflow attaches the exact libusb and libmtp
  tarballs the build used (`release.yml`). *Verified:* the v0.5.0 and v0.6.0 assets include
  `libmtp-1.1.23.tar.gz` and `libusb-1.0.30.tar.bz2`.
- Sparkle's licence (M5): `Sparkle-LICENSE.txt` ships in `Licenses`, `check-release.sh` fails
  without it, the README names it, and Help has an Acknowledgements topic.
- Google's Android SDK License: shown and accepted before any download, acceptance recorded,
  the accepted text bundled; Ferry never redistributes Google's binaries.
- Privacy wording (L11): Help says GitHub and Google see the Mac's IP address, and GitHub which
  versions of Ferry and its updater ask.
- TESTING.md (L12) points to the owner checks below and describes the benchmark.

## Packaging

**Done**
- Signed with Developer ID, hardened runtime, notarized and stapled: the app and the DMG. The
  Sparkle archive and the appcast are attached to the GitHub release, which is published only
  after every check passes. Apple silicon only, as the README states.
  *Verified:* releases 0.2.1 through 0.6.0 built and published by the workflow; 0.4.0 installed
  from the DMG on the owner's Mac.
- A designed DMG background (`Design/DMG/background.svg`, rendered to `background.tiff`, laid out
  by `scripts/dmg-settings.py`).

**Open**
- macOS 26 is the stated minimum (`Package.swift`, `project.yml`, README), but Ferry has only been
  run on macOS 27. Test on 26 (owner check 1) or raise the minimum. (M7)
- The DMG window's layout was never checked on screen in Finder (`scripts/dmg-settings.py`
  says so). Owner check 17.

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
   FerryAgent and the adb server. Relisting should stop about 10 minutes after the last use.
6. **Start-up and menu-open time** on a release build (Instruments, Time Profiler), and helper
   memory after an 8-hour session with a device attached.
7. **VoiceOver:** every menu row, the welcome, the setup guide, Help, the licence window, the log
   and port forwarding windows. **Full Keyboard Access:** reach every control. **Increase
   Contrast**, **Reduce Transparency** and the largest text size: nothing clipped or unreadable.
8. **Updates:** from the previous release by Sparkle, on an admin and on a standard account. There
   is no setting: confirm the update downloads in the background and installs when Ferry quits,
   and note how long it waits while Ferry stays open. **Check for Updates…** when up to date and
   when offline.
9. **Local Network:** the first Wi-Fi connect shows macOS's prompt, and denying it shows Ferry's
   explanation.
10. **Get Android Platform Tools** on a Mac without adb, then offline (clear message), then
    after an update that pins a newer adb.
11. **Remove Ferry**, then check what remains: Finder locations, the login item, the helper, an
    adb server (Ferry's stopped, a user-installed one left running). Both
    `~/Library/Application Support/Ferry` and
    `~/Library/Application Support/io.github.krisarmstrong.ferry.agent` should be in the Trash,
    restorable, not deleted; a folder holding changes the system saved stays in place.
12. **Upgrade over a developer build** (signing identity change): the helper restarts without a
    manual `launchctl` step. The opposite direction, a developer build over Developer ID 0.4.0,
    was proven live (the agent restarted by itself about 12 s after launch); the bootout fallback
    is covered by tests only. This check covers the release build going over a developer one.
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
17. **The DMG window:** open the release DMG in Finder at the default and a larger text size:
    the background, the app and the Applications link line up, and nothing is cut off.

## Audit trail

The W5 audit of v0.4.0 found 0 critical, 1 high, 11 medium, 15 low and 5 informational items;
the finding IDs above (H1, M1–M11, L1–L15) refer to that audit. I1–I5 were informational, with no
action; for I5, the item-table journal is created 0600 and the snapshot keeps the default mode
under `~/Library` (0700). The audit changed no code and did not launch Ferry, so start-up, memory
and live accessibility are the owner checks above. This page was re-verified against `main` at
e8a301e on 2026-11-22.
