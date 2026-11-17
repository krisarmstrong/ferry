# Testing Ferry

`make test lint fmt-check` runs the unit tests (no device needed), SwiftLint and swift-format.

## Device tests

The MTP integration suites write to the attached phone, so they are off by default. Use a phone
you don't mind writing to. Unlock it, choose **File transfer** and quit anything else that might
grab it (Android File Transfer, Image Capture, Preview, Photos).
All device suites sit under one serialized `DeviceTests` parent, because only one session can
hold the phone.

```bash
FERRY_DEVICE_TESTS=1 swift test --filter DeviceTests
# Adds the 4.1 GB upload. It needs about 4.1 GB free on the phone and takes a while.
FERRY_DEVICE_TESTS=1 FERRY_LARGE_FILE_TESTS=1 swift test --filter DeviceTests
# With the phone locked: checks that it reports "locked", not an error.
FERRY_DEVICE_TESTS=1 FERRY_DEVICE_LOCKED=1 swift test --filter MTPDeviceIntegrationTests
```

## Results

v1 supports Android 8 (Oreo) and newer. It needs to pass on the owner's phones and on at least
one Android 8 or 9 device.

| Device | Android | Integration suites | Large file (>4 GB) | Manual checklist | Date |
| ------ | ------- | ------------------ | ------------------ | ---------------- | ---- |
| NetAlly LinkRunner-100G (Android-based; no MoveObject) | AOSP MTP | pass (4/4; locked case not run) | pass | partial — see note | 2026-11-17 |
| Owner's phone | — | not yet run | not yet run | not yet run | — |
| Android 8 or 9 device | 8 / 9 | not yet run | not yet run | not yet run | — |

**LinkRunner-100G, 2026-11-17.** Claimed with Image Capture's `icdd`/`ptpcamerad` running
(see `docs/spikes/2026-11-ptpcamerad.md`). Before file transfer was enabled it exposed no
storage and every command printed the unlock message. Passed with `ferryctl`: `devices`,
`storages`, `ls /`, `put`, `put` without `--replace` refused, `put --replace`, `get` + byte
compare, `get` onto an existing file refused, `mkdir`, `mv` (copy+delete fallback — the device
has no MoveObject), `rename`, `put --replace` onto a folder refused (folder untouched), recursive
`rm`; no `.ferry-partial-*` left. Not run: unplug mid-transfer, case-variant names, accents/emoji,
reconnect key stability by hand, "held by another app".
Large files: `largeFileOver4GB` passed (4.1 GB in 49 s), and a 4.3 GB random-data `put` (48 s,
~90 MB/s) then `get` (35 s, ~123 MB/s) round trip matched by SHA-256, leaving nothing behind on
either side. Internal storage only; no FAT32 SD card to test the >4 GB rejection.

## Manual checklist

Run these with `ferryctl` until Finder integration lands. Record any failure in the table above,
with a note.

### Connect and identify

- `ferryctl devices` lists the phone with its model and serial.
- With no device attached, `ferryctl devices` prints "No device is connected." plus the
  file-transfer steps, and exits 1.
- `ferryctl storages` lists internal storage, plus the SD card if there is one.

### Locked phone

- With the phone locked, every command prints the unlock message, not an error.
- After unlocking and choosing **File transfer**, the same command works without replugging.

### Phone held by another app

- With Image Capture or Android File Transfer holding the phone, commands print the
  "Another app is using the phone" message.

### Browse

- `ls /`, `ls /DCIM` and `ls /Download` match what the phone shows.
- Names with accents and emoji show correctly.

### Copy to and from the phone

- `put` a small file, then `get` it back. The two copies are identical.
- `get` onto an existing local file fails unless you pass `--replace`, and leaves the file as it
  was. Unplug halfway through a large `get`: the local file is unchanged (or absent) and no
  `.ferry-partial-*` file is left beside it.
- `put` over an existing name fails unless you pass `--replace`.
- `put Foo.txt` into a folder that has `foo.txt` fails the same way, naming `foo.txt`. With
  `--replace` it replaces `foo.txt`, and only one file is left.
- Unplug the cable halfway through a large `put`. No file appears under the real name, and the
  next `ls` of that folder shows no `.ferry-partial-*` object.

### Rename, move and delete

- `rename` and `mv` a file, and check the result on the phone.
- `rm` a folder that has subfolders. Everything in it is gone.

### Reconnect

- Unplug and replug. Storage keys and paths are the same as before.
