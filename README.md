# Ferry

Ferry mounts Android phones over MTP so they appear in Finder on macOS.

## Build

Requires macOS 26 and Xcode with Swift 6.4.

```sh
brew install libmtp swiftlint
make build
make test lint fmt-check
```

## ferryctl

A command-line front end that exercises the whole stack against a real phone. Unlock the phone
and choose "File transfer" first.

```sh
swift run ferryctl devices
swift run ferryctl storages
swift run ferryctl ls /DCIM
swift run ferryctl get /DCIM/Camera/photo.jpg ./photo.jpg [--replace]
swift run ferryctl put ./notes.md /Download/notes.md [--replace]
swift run ferryctl mkdir /Download/new
swift run ferryctl mv /Download/notes.md /Download/new
swift run ferryctl rename /Download/new/notes.md renamed.md
swift run ferryctl rm /Download/new
```

`--device <serial>` picks a phone (default: the first) and `--storage <description>` picks a
storage (default: the first). Errors print one line to stderr and exit 1.

Manual write smoke test (use a phone you own, never work equipment):

1. `put README.md /Download/ferry-smoke.md`
2. `get /Download/ferry-smoke.md /tmp/x.md && diff README.md /tmp/x.md`
3. `rm /Download/ferry-smoke.md`
4. With the phone locked, any command prints the unlock message.
