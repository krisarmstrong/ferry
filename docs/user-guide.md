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

Ferry has no published release yet. Build it from source (see the README), then move
**Ferry** to the **Applications** folder and open it.

Ferry runs in the menu bar. It has no Dock icon and no main window.

### First launch

The first time Ferry opens, it starts a small helper that talks to your devices. The helper
keeps running while Ferry is installed, so devices appear in Finder even after you quit the
menu-bar item.

Until the helper answers, the menu shows **Checking…**.

### Turn on Ferry in Finder

macOS asks you to allow Ferry to add locations to Finder. Ferry adds a location the first
time a device is connected; from then until you turn it on, the menu shows
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

The unit appears in Finder a few seconds later. Until you tap **Transfer files**, the menu
shows **No device connected** (the unit offers the Mac no file-transfer connection at all) or
**Not sharing files** (the unit stays visible but shares no storage). Either way, click **How to
connect** or **How to turn on file transfer** for these steps.

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

To see files that were added or changed on the device while it was connected, choose
**Refresh** in the Ferry menu.

### Copy files

- **From the device to the Mac:** drag files or folders from the device's location to a
  folder on the Mac.
- **From the Mac to the device:** drag files or folders onto the device's location, or into
  a folder on it.

Finder shows how far each copy has got, and the Ferry menu lists copies in progress under
their device with a percentage. Ferry writes each file under a hidden temporary name and
renames it only when the copy is complete, so a half-copied file never appears under its real
name.

Packages, such as `.rtfd` documents, copy as folders, and editing one on the device updates
its folder there. Symbolic links and aliases can't be
copied to the device: Finder shows "Symbolic links and aliases can't be copied to the device"
for them, and links inside an app or other bundle are left out of its copy.

### A file changed on both sides

If a file changed on the device (an app on it, or someone at the unit) after the Mac read it,
and you then save your version from the Mac, Ferry keeps the device's version and saves yours
beside it as **name (conflict from Mac)**, for example `report (conflict from Mac).txt`. Finder
then shows the device's version under the original name. Nothing is overwritten.

### Large files

Files larger than 4 GB copy normally to internal storage. Many SD cards use a format (FAT32)
that cannot hold a file larger than 4 GB; Ferry then shows an error rather than copying part
of the file.

### Rename, new folder

Rename files and folders, and create new folders, the same way as on any drive.

### Delete

The device has no Trash. Finder offers **Delete Immediately** instead of **Move to Trash**,
and the file is removed from the device at once. It cannot be recovered from the Mac.

Ferry deletes a folder only together with everything Finder shows in it. If the device added
files to a folder since Finder last showed it, the folder and those files stay, and Finder
puts the folder back. A file the device changed since Finder last showed it is not deleted
either: Finder puts it back with the device's version.

### Free up space on the Mac

When you open a file, macOS keeps a copy on the Mac. To remove that copy and keep the file on
the device, Control-click the file and choose **Remove Download**.

## The menu

Click the Ferry icon in the menu bar to see each connected device, its storage and free space,
and its state.

| State | Meaning |
| ----- | ------- |
| **Ready** | The device is sharing files and is in Finder. The menu lists each storage and its free space. |
| **Not sharing files** | The device is connected but file transfer is off or it is locked. Click **How to turn on file transfer** for the steps. |
| **Ejected** | You ejected the device. It stays out of Finder until you click **Mount**, choose **Refresh**, or unplug it and plug it back in. |
| **In use by another app** | Another app has the device. Quit it, then click **Try Again**. See [Troubleshooting](#in-use-by-another-app). |
| **Can't open** | The device reported an error, shown under its name. Click **Try Again**, or unplug it and plug it back in. |

Above the devices, the menu can also show:

- **Checking…**: Ferry is waiting for its helper to answer, for example just after Ferry opens.
- **Turn on Ferry in Finder**: see [Turn on Ferry in Finder](#turn-on-ferry-in-finder). It
  shows only once a device has been connected, since there is nothing to turn on before.
- **Allow Ferry's helper** or **macOS can't find Ferry's helper**: macOS is not letting the
  helper run. See [Ferry's helper is not responding](#ferrys-helper-is-not-responding).
- A copy in progress, under its device: **Copying "name" to the device** or **to this Mac**,
  with how far it has got.
- **No device connected**, with a **How to connect** button. The first time the menu stays
  open for about 10 seconds with no device, Ferry opens the setup guide.

While the menu is open, Ferry checks for devices every 2 seconds.

Menu items:

- **Refresh** (⌘R): reads each ready device's folders again, so changes made on the device
  show in Finder, mounts every device you ejected, and checks again a device that is not
  sharing files.
- **Eject** (next to a ready device): removes the device from Finder and releases it, so you
  can unplug it or use it with another app. The device then shows **Ejected** until you click
  **Mount**, choose **Refresh**, or unplug it and plug it back in. Changes that had not reached the device
  are saved to a folder on the Mac: the menu says **Unsent changes were saved to** that folder
  and offers **Reveal in Finder**. Deletes and renames that had not reached the device are
  dropped, so the device keeps those files under their old names.
- **Mount** (next to an ejected device): puts it back in Finder.
- **Try Again** (next to a device that is in use or can't open): asks Ferry to open the
  device again.
- **Help** (the question-mark button, ⌘?): opens Ferry Help.
- **Settings…** (⌘,): opens Settings.
- **Quit**: closes the menu-bar item. The helper keeps running, so devices stay in Finder.

Settings:

- **Open at login**: starts the Ferry menu-bar item when you log in.
- **How to connect**: opens the file-transfer steps.
- **Help**: opens Ferry Help.
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
cable. A device you ejected shows **Ejected** instead: click **Mount**.

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

Plug it back in and turn on file transfer again. Finder finishes the copy when the device
reconnects. Nothing is left on the device under the file's real name until the copy is
complete.

### "Ferry's helper is not responding"

If the menu says **Allow Ferry's helper** or **macOS can't find Ferry's helper**, macOS is not
letting the helper run. Click **Open System Settings**, then in **Login Items & Extensions**
turn on **Ferry** under **Allow in the Background**.

If the menu says "Ferry's helper is not responding. Quit Ferry and open it again.", quit Ferry
from the menu and open it again from Applications.

### An app or script from the device does not open at once

Files copied from a device are marked as downloaded, like files from the internet, so macOS
checks an app or script with Gatekeeper before it first opens, and may ask you to confirm.

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
