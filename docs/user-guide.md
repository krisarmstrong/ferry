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
- [Connect over the network](#connect-over-the-network)
- [Using Ferry in Finder](#using-ferry-in-finder)
- [The menu](#the-menu)
- [Tools over USB debugging](#tools-over-usb-debugging)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)
- [Uninstall](#uninstall)

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
connect** or **How to Turn On File Transfer** for these steps.

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
a **Copy** button and a **Check Again** button:

```text
brew install --cask android-platform-tools
```

Click **Check Again** once it is installed. From a device that is serving files over file
transfer, **More Tools with USB Debugging…** in the menu opens the steps below for its model.

### NetAlly LinkRunner 10G, LinkRunner 100G and EtherScope nXG

1. Ask NetAlly to enable ADB on the tester.
2. After that, on the tester: **Settings** → **System** → **About tester**. Tap
   **Build number** until developer mode is on.
3. Go to **Settings** → **System** → **Developer options** and turn on **USB debugging**.
4. With the USB-C cable connected to the Mac, turn **USB debugging** off and on again. The
   tester offers ADB only after this.
5. On the device, tick **Always allow from this computer** and tap **OK**.

### Android 8 or 9

1. Unlock the phone and connect it to the Mac with a USB cable. Its storage stays hidden while
   it is locked.
2. Open **Settings** → **System** → **About phone** and tap **Build number** until developer
   mode is on.
3. Open **Settings** → **System** → **Developer options** and turn on **USB debugging**.
4. On the device, tick **Always allow from this computer** and tap **OK**.

### Android 10 or newer

1. Unlock the phone and connect it to the Mac with a USB cable. Its storage stays hidden while
   it is locked.
2. Open **Settings** → **About phone** and tap **Build number** until developer mode is on.
3. Open **Settings** → **System** → **Developer options** and turn on **USB debugging**.
4. On the device, tick **Always allow from this computer** and tap **Allow**.

Menu names vary a little between phone makers. Look for Developer options and the USB
debugging switch.

If the device accepts ADB over the network, use **Connect by Address…**.

## Connect over the network

Ferry can reach a device over ADB on your network as well as by cable. It never searches the
network: it connects only to addresses you give it, and to the addresses a device on USB
debugging reports for itself. A device that is also on a cable is always served by the cable.

- **Use over Wi-Fi** suits a device already on USB debugging, such as a NetAlly tester or a
  phone with Android 8 to 10.
- **Pair with Code** is for Android 11 and newer.
- **Connect by Address** is for a device that already accepts ADB over the network.

### Use over Wi-Fi

With the device on USB debugging and connected by cable, click the device in the menu, then
**Use over Wi-Fi**. Ferry reads the device's Ethernet and Wi-Fi addresses, turns on ADB over the
network if it is off, and connects to the first address that answers. Connect the device to
Ethernet or Wi-Fi first.

Turning it on restarts ADB on the device, so Ferry refuses while the device has a transfer, a
screen recording or a log running: let it finish, then try again.

### Pair with Code

On the device, open **Developer options** → **Wireless debugging** and choose **Pair device with
pairing code**. In Ferry's menu, click **Pair with Code…**, enter the IP address and port and
the code the device shows, and click **Pair**. Ferry then connects to the address the device
offers for connections, which is not the one it paired on.

### Connect by Address

Click **Connect by Address…**, type the device's IP address or name, and click **Connect**.
Ferry uses adb's usual port unless you add another after a colon. If the device asks, tap
**Allow** on it: the menu shows that it is waiting until you do.

### Remembered devices

Ferry remembers each device it connects this way by its serial number, and connects to it again
when Ferry starts and when adb restarts. A remembered device it cannot reach shows **Remembered
· not nearby**: click it, then **Connect Again** to try again.

**Forget** disconnects the device and forgets its addresses. Ferry no longer connects to it by
itself.

### "Is this address your device?"

Anyone on a network can claim a device's serial number. So when a new address answers as a
device Ferry already knows, Ferry does not use it on its own: the menu asks
"Is *address* your *device*?", with the address and the name Ferry has for the device.
**Use It** connects the address and remembers it for that device. **Ignore** leaves it unused
until Ferry restarts.

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

Changes made on the device while it is connected reach Finder on their own:

- Over USB debugging or Wi-Fi, Ferry watches the folders you have open, so changes show up
  within a few seconds, and within about 30 seconds at most.
- In file transfer mode, new and deleted files show up within about 30 seconds. A file that was
  changed in place or renamed on the device shows only after you choose **Refresh** in the
  Ferry menu.

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

### Send to a device from Finder

Control-click files anywhere on the Mac and choose **Send to** and the device (for example
**Send to LinkRunner 10G**). Ferry copies them into the `Download` folder on the device's
internal storage, and makes that folder if the device has none. Ferry's button in the Finder
toolbar has the same menu: add it with **View** → **Customize Toolbar**. With no device
connected, the menu says **No device connected**.

Sending never replaces a file. If `Download` already has one with the same name, Ferry keeps it
and saves yours beside it as **name (conflict from Mac)**, as for a file changed on both sides.

Only files can be sent this way. A folder shows "Folders can't be sent from this menu. Copy the
folder into the device's location in Finder, or compress it into a .zip first." A package, such
as an `.rtfd` document or an app, and a symbolic link or alias are refused with the same
messages Finder shows when you copy them to the device.

When every selected file is an `.apk` and Ferry reaches the device over ADB (with USB debugging
on, or over Wi-Fi), the menu also has **Install on** the device. It installs each app
as **Install App…** in the menu does.

Finder shows no progress for these. A notification says when the files are on the device or the
apps are installed, or why not. The Ferry menu shows a send in progress when you click its
device.

To turn on the Finder menu, once:

1. Open System Settings, then **General** → **Login Items & Extensions**.
2. Under Extensions, find Ferry's Finder extension and turn it on.

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
name the Mac can't show (Finder leaves that file out of the folder): delete it on the device. A
file the device changed since Finder last showed it is not deleted either: Finder puts it back
with the device's version.

### Free up space on the Mac

When you open a file, macOS keeps a copy on the Mac. To remove that copy and keep the file on
the device, Control-click the file and choose **Remove Download**.

## The menu

Click the Ferry icon in the menu bar to see each connected device. Each one is a row with a
round tile (in color while Ferry serves the device, grey otherwise), its name, and a line under
the name: how Ferry reaches it and its free space, such as **USB · 21 GB free**, its address
over Wi-Fi, or its state. Click a device to see what you can do with it, and click it again to
close it. One device is open at a time; the first ready one is open when the menu opens.

| State | Meaning |
| ----- | ------- |
| **Ready** | The device is sharing files and is in Finder. Click it to see each storage and its free space. |
| **Not sharing files** | The device is connected but file transfer is off or it is locked. Click **How to Turn On File Transfer** for the steps. |
| **Ejected** | You ejected the device. It stays out of Finder until you click **Mount**, choose **Refresh**, or unplug it and plug it back in. |
| **In use by another app** | Another app has the device. Quit it, then click **Check Again**. See [Troubleshooting](#in-use-by-another-app). |
| **Can't open** | The device reported an error, shown when you click it. Click **Check Again**, or unplug it and plug it back in. |

Above the devices, the menu can also show:

- **Checking…**: Ferry is waiting for its helper to answer, for example just after Ferry opens.
- **Turn on Ferry in Finder**: see [Turn on Ferry in Finder](#turn-on-ferry-in-finder). It
  shows only once a device has been connected, since there is nothing to turn on before.
- **Allow Ferry's helper** or **macOS can't find Ferry's helper**: macOS is not letting the
  helper run. See [Ferry's helper is not responding](#ferrys-helper-is-not-responding).
- A copy in progress, when you click its device: **Copying "name" to the device** or **to this
  Mac**, with how far it has got.
- **No device connected**, with **How to Connect** under it. The first time the menu stays
  open for about 10 seconds with no device, Ferry opens the setup guide.

While the menu is open, Ferry checks for devices every 2 seconds.

A device over ADB (with USB debugging on, or over Wi-Fi) lists the
[tools](#tools-over-usb-debugging) when you click it. A device on file transfer also shows
**More Tools with USB Debugging…**, which opens the [steps](#usb-debugging-adb), or **Allow USB
debugging on the device** once USB debugging is on and waits for you to tap **Allow**. When
`adb` is not installed and a device is connected, the menu shows **Install adb for more
tools…**. When `adb` is installed but its server is not answering, it shows **adb isn't
running** with **Check Again**. A device on your network that waits for you to allow this Mac
shows **Waiting for you to allow this Mac on** its address.

Menu items:

- **Refresh** (⌘R): reads each ready device's folders again at once, so every change made on
  the device shows in Finder, including files changed in place or renamed in file transfer
  mode; mounts every device you ejected; and checks again a device that is not sharing files.
- **Eject** (in a ready device's list): removes the device from Finder and releases it, so you
  can unplug it or use it with another app. The device then shows **Ejected** until you click
  **Mount**, choose **Refresh**, or unplug it and plug it back in. Changes that had not reached
  the device are saved to a folder on the Mac: the menu says **Unsent changes were saved to**
  that folder and offers **Reveal in Finder**. Deletes and renames that had not reached the
  device are dropped, so the device keeps those files under their old names.
- **Mount** (in an ejected device's list): puts it back in Finder.
- **Check Again** (in the list of a device that is in use or can't open): asks Ferry to open
  the device again.
- **Send File…** (in a ready device's list): sends files you choose into the device's
  `Download` folder, as **Send to** does in Finder.
- **Help** (⌘?): opens Ferry Help.
- **Settings…** (⌘,): opens Settings.
- **Quit Ferry** (⌘Q): closes the menu-bar item. The helper keeps running, so devices stay in
  Finder.

Settings:

- **Open at login**: starts the Ferry menu-bar item when you log in.
- **How to Connect**: opens the setup guide, on file transfer or USB debugging.
- **Help**: opens Ferry Help.
- **Remove Ferry…**: see [Uninstall](#uninstall).

## Tools over USB debugging

Click a device Ferry reaches over ADB, with USB debugging on or over Wi-Fi, to see its details,
**Copy Device Details**, and its tools: **Take Screenshot**, **Record Screen**, **Logcat**,
**Port Forwarding**, **Install App…** and **Open Shell**. A device on file transfer shows **More Tools
with USB Debugging…** instead.

### Install an app

Click **Install App…** and choose an `.apk` file, or drag one `.apk` onto the device in the
menu. Ferry checks that the file is an Android app, copies it to the device and installs it,
replacing an older version of the same app. The menu shows how far the copy has got, then says
when the app is installed.

If the device refuses the app, the menu says why, for example that a newer version is installed
or that the app needs a newer version of Android. Ferry removes its copy of the app from the
device either way.

### Screenshots and screen recordings

Click **Take Screenshot** to save what the device's screen shows. Click **Record Screen** to
record it, for up to three minutes; the menu shows how long it has been recording, and **Stop
Recording** ends it.

Ferry saves them in `Documents/Ferry/<device>/`, screenshots in `Screenshots` and recordings in
`Screen Recordings`, named like macOS's own, such as
`Screenshot LinkRunner-100G 2026-11-18 at 17.09.27.png`, and shows them in Finder. macOS asks
whether Ferry may use Documents the first time it saves one. It never replaces a file. A
recording waits on the device until Ferry has saved it, even if you quit Ferry meanwhile; Ferry
then removes it from the device.

If Ferry can't save a recording, the menu shows **Recording couldn't be saved**:
**Choose Folder…** saves it where you pick, and **Discard** deletes it from the device.
**Record Screen** returns once it is saved or discarded. An ejected device keeps its recording
until Ferry serves it again.

Ferry turns the device's screen on before a screenshot or a recording, so a screen that was off
is not captured black. A recording of a screen that does not change has a single frame.

### Logcat

Click **Logcat** to watch the device's log in a window of its own.
Ferry keeps the newest 50,000 lines. **Level** shows lines at that level and above, and
**Filter** shows the lines that contain your text, whatever its case. **Pause** freezes the
window while lines keep arriving, and **Resume** catches up. **Clear** empties it.

**Save…** writes the lines that match the filters to a plain text file where you choose. The log
stops when you close the window or the device goes away.

### Open a shell

Click **Open Shell** to open Terminal with a shell on the device
(`adb shell`). Ferry needs adb for this, and says so if it can't find it. Nothing on the device
changes unless you type a command that changes it.

### Forward a port

Click **Port Forwarding** to send connections to a port on this Mac
to a port on the device. Type the port on this Mac (1024 or higher) and the port on the device,
then click **Add**. **Remove** ends a forward.

If the port on this Mac is already in use, the window shows adb's message. Ferry lists only the
TCP forwards adb holds for this device.

### Device details

An open device lists its network ports with their IPv4 addresses, then its Android version and
battery. For a model Ferry knows, every port is listed by the name on the unit, with **Not
connected** for one that has no address. Ferry only reads them, when you open the device and
every 10 seconds while the menu stays open.

Click an address to copy it; the line shows **Copied** for a moment. **Copy Device Details**,
just under the details, copies everything the device reports: model, Android version, build, serial number, battery, every
address on every port including IPv6, and storage.

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
**Check Again**:

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
