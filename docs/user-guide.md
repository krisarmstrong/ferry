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
- [USB debugging (ADB)](#usb-debugging-adb)
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

## USB debugging (ADB)

File transfer is enough to browse and copy. With USB debugging on, Ferry serves the device over
ADB instead, which is faster and adds more tools. File transfer keeps working without it, and
Ferry falls back to it whenever ADB is off.

Ferry needs `adb`, from Google's Android platform tools. It never installs or bundles it. If it
is missing, the menu shows **Install adb for more tools…** with the command to run in Terminal,
a **Copy** button and a **Check again** button:

```text
brew install --cask android-platform-tools
```

Click **Check again** once it is installed. From a device that is serving files over file
transfer, **More tools with USB debugging…** in the menu opens the steps below for its model.

### NetAlly LinkRunner 10G, LinkRunner 100G and EtherScope nXG

1. Ask NetAlly to enable ADB on the tester.
2. After that, on the tester: **Settings** → **System** → **About tester**. Tap
   **Build number** until developer mode is on.
3. Go to **Settings** → **System** → **Developer options** and turn on **USB debugging**.
4. With the USB-C cable connected to the Mac, turn **USB debugging** off and on again. The tester
   offers ADB only after this.
5. On the device, tick **Always allow from this computer** and tap **OK**.

Once ADB is enabled, NetAlly testers also listen for ADB over the network on port 5555.

### Android 8 or 9

1. Unlock the phone and connect it to the Mac with a USB cable.
2. Open **Settings** → **System** → **About phone** and tap **Build number** until developer
   mode is on.
3. Open **Settings** → **System** → **Developer options** and turn on **USB debugging**.
4. On the device, tick **Always allow from this computer** and tap **OK**.

### Android 10 or newer

1. Unlock the phone and connect it to the Mac with a USB cable.
2. Open **Settings** → **About phone** and tap **Build number** until developer mode is on.
3. Open **Settings** → **System** → **Developer options** and turn on **USB debugging**.
4. On the device, tick **Always allow from this computer** and tap **Allow**.

Menu names vary a little between phone makers. Look for Developer options and the USB
debugging switch.

Until you tap **OK** or **Allow**, the menu shows **Allow USB debugging on the device** and
Ferry keeps serving the device over file transfer. A device that only adb lists shows
**Waiting for Allow** instead of a state. The method it uses shows under each ready device.

## Using Ferry in Finder

### Where to find your device

Each device appears in Finder's sidebar under **Locations**. A device with an SD card shows
two locations: the internal storage, and the card with " – SD card" after the name. If two
devices of the same model are connected, each name ends with the last four characters of
its serial number. The SD card has one location over USB debugging and another over File
transfer, because File transfer cannot tell one card from another of the same kind.

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

Ferry copies files and folders. A package, such as an `.rtfd` or Keynote document, an app, a
plug-in or a framework, is one item on the Mac but a folder on the device, so Ferry does not
copy it: Finder shows "Packages and app bundles can't be copied to the device. Compress it into
a .zip first." Control-click it, choose **Compress**, and copy the `.zip`. Symbolic links and
aliases can't be copied to the device either: Finder shows "Symbolic links and aliases can't be
copied to the device" for them.

A folder on the device named like an app or a document package (`Tool.app`, `Notes.rtfd`)
shows in Finder as an app or a document, because macOS goes by the name. Such a folder, and
everything in it, is read-only on the Mac: an app saving it would replace the whole folder,
which Ferry can't copy. Edit it on the device, or copy it to the Mac. Something you put inside
one stays on the Mac only: Finder shows "Folders named like an app or a document package, and
what they hold, can't be changed from this Mac. Change them on the device." For the same
reason a folder on the device can't be renamed to such a name. Android's app folders, such as
`Android/data/com.example.app`, count too: macOS reads `.app` as an app.

Saving such a document from a Mac app (TextEdit, Keynote) is not sent to the device either.
The app may leave a copy beside it, such as `Notes 2.rtfd`, which Finder marks with an error:
your edit is only in that copy, on the Mac. To keep it, copy it to a folder on the Mac. Edit
these documents on the device, or copy them to the Mac first.

To remove such a folder, delete it on the device, or delete the folder that holds it from
Finder. Finder may put the holding folder back once, if it had not shown everything inside;
delete it again.

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

Ferry deletes a folder with its contents only if Finder has shown everything in it, at every
level, as it is now on the device. If anything inside it is new or changed on the device, or a
folder inside it was never opened in Finder, the whole folder stays and Finder puts it back,
showing what is there; delete it again to remove it. A folder nested more than 64 levels deep,
or holding more than 100,000 items, also stays, and so does a folder that holds a file whose
name the Mac can't show (Finder leaves that file out of the folder): delete it on the device. A file
the device changed since Finder last showed it is not deleted either: Finder puts it back with
the device's version.

### Free up space on the Mac

When you open a file, macOS keeps a copy on the Mac. To remove that copy and keep the file on
the device, Control-click the file and choose **Remove Download**.

## The menu

Click the Ferry icon in the menu bar to see each connected device, how Ferry reaches it, its
storage and free space, and its state.

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

Under each ready device, the menu says how Ferry reaches it:

| Shown | Meaning |
| ----- | ------- |
| **USB · ADB** | ADB over a USB cable. |
| **Wi-Fi · ADB** | ADB over your network. |
| **USB · File transfer** | USB file transfer, with USB debugging off or not yet allowed. |

A device over ADB shows the [tools](#tools-over-usb-debugging) under its name. A device on
file transfer also shows **More tools with USB debugging…**, which opens the
[steps](#usb-debugging-adb), or **Allow USB debugging on the device** once USB debugging is on
and waits for you to tap **Allow**. When `adb` is not installed and a device is connected, the
menu shows **Install adb for more tools…**. When `adb` is installed but its server is not
answering, it shows **adb isn't running** with **Check again**. A device on your network that
waits for you to allow this Mac shows **Waiting for you to allow this Mac on** its address.

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
- **How to connect**: opens the setup guide, on file transfer or USB debugging.
- **Help**: opens Ferry Help.
- **Remove Ferry…**: see [Uninstall](#uninstall).

## Tools over USB debugging

A device Ferry reaches over ADB (**USB · ADB** or **Wi-Fi · ADB** in the menu) shows
**Install App…**, **Screenshot** and **Record Screen** under its name, and a **Developer
Tools** menu. A device on file transfer shows **More tools with USB debugging…** instead.

### Install an app

Click **Install App…** and choose an `.apk` file, or drag one `.apk` onto the device in the
menu. Ferry checks that the file is an Android app, copies it to the device and installs it,
replacing an older version of the same app. The menu shows how far the copy has got, then says
when the app is installed.

If the device refuses the app, the menu says why, for example that a newer version is installed
or that the app needs a newer version of Android. Ferry removes its copy of the app from the
device either way.

### Screenshots and screen recordings

Click **Screenshot** to save what the device's screen shows. Click **Record Screen** to record
it, for up to three minutes; the menu shows how long it has been recording, and **Stop** ends
it.

Ferry saves them where macOS saves its own screenshots (the Desktop, unless you chose another
folder in the Screenshot app), named like macOS's own, such as
`Screenshot LinkRunner-100G 2026-11-18 at 17.09.27.png`, and shows them in Finder. It never
replaces a file. A recording waits on the device until Ferry has saved it, even if you quit
Ferry meanwhile; Ferry then removes it from the device.

If Ferry can't save a recording, the menu shows **Recording couldn't be saved**:
**Choose Folder…** saves it where you pick, and **Discard** deletes it from the device.
**Record Screen** returns once it is saved or discarded. An ejected device keeps its recording
until Ferry serves it again.

A device whose screen is off sends a black screenshot, and a recording of a screen that does not
change has a single frame.

### Logcat

Choose **Developer Tools**, then **Logcat…**, to watch the device's log in a window of its own.
Ferry keeps the newest 50,000 lines. **Level** shows lines at that level and above, and
**Filter** shows the lines that contain your text, whatever its case. **Pause** freezes the
window while lines keep arriving, and **Resume** catches up. **Clear** empties it.

**Save…** writes the lines that match the filters to a plain text file where you choose. The log
stops when you close the window or the device goes away.

### Open a shell

Choose **Developer Tools**, then **Open Shell**, to open Terminal with a shell on the device
(`adb shell`). Ferry needs adb for this, and says so if it can't find it. Nothing on the device
changes unless you type a command that changes it.

### Forward a port

Choose **Developer Tools**, then **Port Forwarding…**, to send connections to a port on this Mac
to a port on the device. Type the port on this Mac (1024 or higher) and the port on the device,
then click **Add**. **Remove** ends a forward.

If the port on this Mac is already in use, the window shows adb's message. Ferry lists only the
TCP forwards adb holds for this device.

### Device info

Choose **Developer Tools**, then **Device Info…**, to see the model, Android version, build,
serial number, battery, IP addresses and storage the device reports. Ferry only reads them.
**Copy** puts them on the clipboard.

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

### "Packages and app bundles can't be copied to the device"

A package, such as an `.rtfd` or Keynote document, an app, a plug-in or a framework, is one item
on the Mac but a folder on the device, so Ferry does not copy it. Control-click it, choose
**Compress**, and copy the `.zip` instead.

### An app or script from the device does not open at once

Files copied from a device are marked as downloaded, like files from the internet, so macOS
checks an app or script with Gatekeeper before it first opens, and may ask you to confirm. A
folder on the device named like an app or a document package (`Tool.app`, `Notes.rtfd`) shows
in Finder as one, and is marked the same way.

## Privacy

Ferry has no telemetry, analytics, crash reporting or account, and sends nothing to any server.
Your files go only between the device and your Mac. If you use ADB over Wi-Fi, Ferry talks to
that device on your network and nowhere else.

## Uninstall

1. Open Ferry's **Settings** and click **Remove Ferry…**, then confirm.
   Your devices disappear from Finder, Ferry's helper stops and Ferry quits. Files on your
   devices are not touched.
2. Drag **Ferry** from Applications to the Trash.

Do step 1 first. It is the step that removes the Finder locations and stops the helper.

## Coming next

- **Pair and connect over Wi-Fi from Ferry**: today Ferry uses network devices that adb
  already lists.
- **Send to device** in Finder: send selected files to a connected device from the
  Control-click menu.
