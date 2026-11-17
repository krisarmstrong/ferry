# Spike: can Ferry claim the device while macOS's Image Capture stack runs?

Date: 2026-11-17 · macOS 27.2 (Apple silicon) · libmtp 1.1.23 / libusb 1.0.30 (Homebrew)

Device: NetAlly LinkRunner-100G (Android-based; USB VID 18d1 / PID 4ee1, which
libmtp matches as "Google Nexus/Pixel (MTP)"); serial `0123456789abcdef`.

## Results

| Condition | `ptpcamerad` | Other claimers | libmtp open (`mtp-detect`, `ferryctl devices`) | Storage |
|---|---|---|---|---|
| Nothing extra running | not running | `icdd` (Image Capture device daemon) running | **opened** | not exposed (`Get Storage information failed`) |
| Image Capture.app + Preview.app open | **running** (spawned by Image Capture) | `icdd`, Image Capture, Preview | **opened** | not exposed |
| After quitting both apps | exits on its own | — | — | — |

libmtp logs `avoid probing device using attached kernel interface` and
claims the interface anyway; neither `icdd` nor `ptpcamerad` held it
exclusively. Stopping `ptpcamerad` (step 3 of the plan) was not needed and was
not done.

`ferryctl storages` reports `Unlock your phone and choose "File transfer".`
— the device enumerates over MTP but publishes no storage until file transfer
is enabled on the device itself. That is the locked/charge-only state the
design already handles, not a claim conflict.

## Not yet covered

- An Android phone (Pixel/Samsung) and an Android 8/9 device: their MTP stack
  is AOSP's, like the LinkRunner's, but untested.
- Google Drive / Dropbox / Android File Transfer running (not installed here).
- A device with storage exposed — needed before the gated device tests can run.

Decision: step 1
