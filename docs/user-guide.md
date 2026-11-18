# Ferry user guide

Ferry shows Android devices as locations in Finder on your Mac. It was built first for NetAlly
network testers (LinkRunner 10G, EtherScope nXG and LinkRunner 100G), and it works with other
Android phones too. Plug the device in with a USB cable, turn on file transfer on the device,
and it appears in Finder's sidebar. You can then browse, open and copy files as you would on
any drive.

Ferry is free and open source (MIT). It needs macOS 26 or later on an Apple silicon Mac.

- [Getting started](#getting-started)
- [Connect a NetAlly unit](#connect-a-netally-unit)
- [Connect another Android phone](#connect-another-android-phone)
- [Using Ferry in Finder](#using-ferry-in-finder)
- [The menu](#the-menu)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)
- [Uninstall](#uninstall)
- [Coming next](#coming-next)

## Getting started

### Install

1. Download the latest `Ferry.dmg` from the project's GitHub Releases page.
2. Open the DMG and drag **Ferry** to the **Applications** folder.
3. Open Ferry from Applications.

Ferry runs in the menu bar. It has no Dock icon and no main window.

### First launch

The first time Ferry opens, it starts a small helper that talks to your devices. The helper
keeps running while Ferry is installed, so devices appear in Finder even when the menu-bar
item is closed.

### Turn on Ferry in Finder

macOS asks you to allow Ferry to add locations to Finder. Until you do, the menu shows
**Turn on Ferry in Finder**.

1. Click the Ferry icon in the menu bar.
2. Click **Open System Settings**.
3. In **Login Items & Extensions**, turn on **Ferry** under **File Providers**.

You only do this once. It stays on after Ferry or the Mac restarts.

## Connect a NetAlly unit

These steps apply to the **LinkRunner 10G**, **EtherScope nXG** and **LinkRunner 100G**.
They come from each model's user guide; the guides say "PC or tablet", and a Mac works the
same way.

1. Connect a USB-C cable to the **USB-C port on the left side** of the unit and to the Mac.
2. On the unit: **Settings** (bottom of the Home screen) → **Connected devices** → **USB**.
3. Tap **Transfer files**.

The unit appears in Finder a few seconds later. Until you tap **Transfer files**, the unit is
connected but shares no storage, and Ferry's menu shows **Not sharing files**.

AirCheck G3 support is planned; it uses different steps.

## Connect another Android phone

Unlock the phone first. Android hides the phone's storage while it is locked.

### Android 8 or 9

1. Unlock the phone and connect it to the Mac with a USB cable.
2. Pull down the notification shade and tap **USB charging this device**.
3. Tap **Transfer files**.

### Android 10 or newer

1. Unlock the phone and connect it to the Mac with a USB cable.
2. Pull down the notification shade and tap **Charging this device via USB**.
3. Under **USB preferences**, choose **File transfer**. Or open **Settings** →
   **Connected devices** → **USB**.

Menu names vary a little between phone makers. Look for the USB notification and the option
that mentions file transfer.

## Using Ferry in Finder

### Where to find your device

Each device appears in Finder's sidebar under **Locations**. A device with an SD card shows
two locations: the internal storage, and the card with " – SD card" after the name. If two
devices of the same model are connected, each name ends with the last four characters of
its serial number.

Your devices also appear in every app's Open and Save dialogs.

### Browse and open

Click a folder to see what is in it. Double-click a file to open it. Ferry copies the file to
the Mac when you open it, so a large file can take a moment the first time.

To see files that were added on the device while it was connected, choose **Refresh** in the
Ferry menu.

### Copy files

- **From the device to the Mac:** drag files or folders from the device's location to a
  folder on the Mac.
- **From the Mac to the device:** drag files or folders onto the device's location, or into
  a folder on it.

Finder shows the progress. Ferry writes each file under a hidden temporary name and renames it
only when the copy is complete, so a half-copied file never appears under its real name.

### Large files

Files larger than 4 GB copy normally to internal storage. Many SD cards use a format (FAT32)
that cannot hold a file larger than 4 GB; Ferry then shows an error rather than copying part
of the file.

### Rename, new folder

Rename files and folders, and create new folders, the same way as on any drive.

### Delete

The device has no Trash. Finder offers **Delete Immediately** instead of **Move to Trash**,
and the file is removed from the device at once. It cannot be recovered from the Mac.

### Free up space on the Mac

When you open a file, macOS keeps a copy on the Mac. To remove that copy and keep the file on
the device, Control-click the file and choose **Remove Download**.

## The menu

Click the Ferry icon in the menu bar to see each connected device, its storage and free space,
and its state.

| State | Meaning |
| ----- | ------- |
| **Ready** | The device is sharing files and is in Finder. |
| **Not sharing files** | The device is connected but file transfer is off. Click **How to turn on file transfer** for the steps. |
| **In use by another app** | Another app has the device. See [Troubleshooting](#in-use-by-another-app). |
| **Checking…** | Ferry is checking the device again, for example after **Try Again**. |
| **Can't open** | The device reported an error. Click **Try Again**, or unplug it and plug it back in. |

With no device connected, the menu shows **No device connected** and a **How to connect** link.

Menu items:

- **Refresh** (⌘R): checks for devices again and shows changes made on the device.
- **Eject** (next to a device): removes the device from Finder and releases it, so you can
  unplug it or use it with another app. Changes that had not reached the device are saved to a
  folder on the Mac, and the menu offers **Reveal in Finder**.
- **Settings…** (⌘,): opens Settings.
- **Quit**: closes the menu-bar item. The helper keeps running, so devices stay in Finder.

Settings:

- **Open at login**: starts the Ferry menu-bar item when you log in.
- **How to connect**: opens the file-transfer steps.
- **Remove Ferry…**: see [Uninstall](#uninstall).

## Troubleshooting

### The device does not show up

1. Check the cable. Some USB cables carry power only. Try another cable or port.
2. Unlock the device.
3. Turn on file transfer: see [Connect a NetAlly unit](#connect-a-netally-unit) or
   [Connect another Android phone](#connect-another-android-phone).
4. Check that Ferry is turned on under **File Providers** (see
   [Turn on Ferry in Finder](#turn-on-ferry-in-finder)).
5. Choose **Refresh** in the Ferry menu.

### "Not sharing files"

The device is connected, but file transfer is off or the device is locked. Unlock it and
choose **Transfer files** (or **File transfer**) on the device. You do not need to replug the
cable.

### "In use by another app"

Only one app can use the device at a time. Quit any of these that are open, then click
**Try Again**:

- Image Capture
- Preview
- Android File Transfer
- MacDroid
- OpenMTP

Photos, Google Drive and Dropbox can also grab a phone when it is plugged in.

### The sidebar shows "Ferry" instead of the device name

When only one device location exists, macOS labels it in the sidebar with the app's name,
"Ferry". This is how macOS shows it, not an error. The device name shows when two or more
locations are present.

### The device was unplugged during a copy

Plug it back in and turn on file transfer again. The copy resumes when the device is
reconnected. Nothing is left on the device under the file's real name until the copy is
complete.

### "Ferry's helper is not responding"

Quit Ferry from the menu and open it again from Applications.

## Privacy

Ferry does not use the network. It has no telemetry, analytics, crash reporting or account.
Your files go only between the device and your Mac; nothing leaves the Mac.

## Uninstall

1. Open Ferry's **Settings** and click **Remove Ferry…**, then confirm.
   Your devices disappear from Finder, Ferry's helper stops and Ferry quits. Files on your
   devices are not touched.
2. Drag **Ferry** from Applications to the Trash.

Do step 1 first. It is the step that removes the Finder locations and stops the helper.

## Coming next

- **ADB connection**, for devices with USB debugging turned on.
- **Wi-Fi connection**, without a cable.
- **Send to device** in Finder: send selected files to a connected device from the
  Control-click menu.
