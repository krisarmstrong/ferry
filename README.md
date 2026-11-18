<p align="center">
  <img src="Design/Icon/Ferry.png" width="128" height="128" alt="Ferry icon">
</p>

<h1 align="center">Ferry</h1>

<p align="center">Android devices in Finder, over USB.</p>

Ferry is a small menu-bar app that shows Android devices as locations in Finder. It was built
for field engineers who carry NetAlly network testers (LinkRunner 10G, EtherScope nXG,
LinkRunner 100G) and need to move test results, captures and files between the tester and a
Mac. It works with other Android phones too. macOS has no built-in way to browse an Android
device over USB; Ferry adds one that uses Finder itself, so you browse, open, copy, rename and
delete with the tools you already know, including any app's Open and Save dialogs. It is free
and open source (MIT), and it never uses the network.

<!-- Screenshots: add once captured on macOS 26, as docs/screenshots/{finder,menu,guide}.png.

| Finder | Menu | Setup guide |
| ------ | ---- | ----------- |
| ![A NetAlly unit as a Finder location](docs/screenshots/finder.png) | ![The Ferry menu with one device](docs/screenshots/menu.png) | ![Steps to turn on file transfer](docs/screenshots/guide.png) |
-->

## Requirements

- macOS 26 or later, Apple silicon
- A USB cable that carries data
- An Android device with file transfer (MTP): NetAlly LinkRunner 10G, EtherScope nXG,
  LinkRunner 100G, or an Android 8+ phone

## Install

There is no published release yet; build Ferry from source (below).

1. Run `make app`, then move `Ferry.app` from `.build/xcode/Build/Products/Debug` to
   **Applications** and open it.
2. In **System Settings → General → Login Items & Extensions**, turn on **Ferry** under
   **File Providers**. The Ferry menu has a button that opens the right page.

A signed release DMG and a Homebrew cask are planned.

## Quick start

**NetAlly LinkRunner 10G, EtherScope nXG, LinkRunner 100G**

1. Connect a USB-C cable to the **USB-C port on the left side** of the unit and to the Mac.
2. On the unit: **Settings** → **Connected devices** → **USB**.
3. Tap **Transfer files**.

**Other Android phones:** unlock the phone, tap the USB notification and choose
**Transfer files** (Android 8–9) or **File transfer** (Android 10 and newer).

The device appears in Finder's sidebar under **Locations**. If it does not, see
[Troubleshooting](docs/user-guide.md#troubleshooting).

Full instructions: [User guide](docs/user-guide.md). The same help is in the app: click the
question-mark button in the Ferry menu.

## Build from source

Requires Xcode 27 (Swift 6.4), [XcodeGen](https://github.com/yonaskolb/XcodeGen),
SwiftLint and Homebrew's libmtp.

```sh
brew install libmtp swiftlint xcodegen

make app     # Ferry.app, with its helper and Finder extension, in .build/xcode/Build/Products/Debug
make test    # unit tests, no device needed
make lint fmt-check
```

`make app` signs with an Apple Development identity of the team in `FERRY_TEAM_ID`
(`project.yml`; the project's own team by default). To build with your own team, pass its
ten-character team ID:

```sh
make app TEAM=ABCDE12345
```

The team ID also names Ferry's app group and its helper's XPC service, and the app, helper and
Finder extension only talk to each other when signed by that team, so all three take it from the
build (each records it as `FerryTeamID` in its Info.plist). `make app` checks that every part
carries it. Device integration tests are off by default; see [docs/TESTING.md](docs/TESTING.md).

`ferryctl` is a command-line front end for testing against a real device. Turn on file
transfer first, then:

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

`--device <serial>` picks a device (default: the first) and `--storage <description>` picks a
storage (default: the first).

## License

Ferry is released under the [MIT License](LICENSE).

Ferry uses [libmtp](https://github.com/libmtp/libmtp) and
[libusb](https://github.com/libusb/libusb), which are licensed under the GNU Lesser General
Public License, version 2.1. Ferry links them dynamically. Development builds load the copies
Homebrew installs; release builds are planned to ship the unmodified libraries in
`Ferry.app/Contents/Frameworks` with their license texts. Their source code is available from
the links above.

NetAlly, LinkRunner, EtherScope and AirCheck are trademarks of NetAlly. Ferry is not affiliated
with or endorsed by NetAlly. Android is a trademark of Google LLC.
