# Ferry user guide

<!-- Generated from Sources/FerryUI/help.json by `make guide`. Edit help.json, not this file. -->

Ferry shows Android devices as locations in Finder on your Mac. It was built first for network testers, the LinkRunner 10G, EtherScope nXG and LinkRunner 100G, and it works with other Android phones too.

This guide holds the same help as **Help** in the Ferry menu, plus how to install Ferry. Ferry is free and open source (MIT). It needs macOS 26 or later on an Apple silicon Mac.

## Contents

- [Install](#install)
- [Getting started](#getting-started)
  - [What Ferry does](#what-ferry-does)
  - [Turn on Ferry in Finder](#turn-on-ferry-in-finder)
  - [Connect your first device](#connect-your-first-device)
- [Connecting](#connecting)
  - [Connect a network tester](#connect-a-network-tester)
  - [Connect an Android phone](#connect-an-android-phone)
  - [Turn on USB debugging](#turn-on-usb-debugging)
  - [Get adb](#get-adb)
  - [Allow this Mac on the device](#allow-this-mac-on-the-device)
  - [Use a device over Wi-Fi](#use-a-device-over-wi-fi)
  - [Connect by address](#connect-by-address)
  - [Pair with a code](#pair-with-a-code)
  - [Remembered devices](#remembered-devices)
- [Files in Finder](#files-in-finder)
  - [Find your device in Finder](#find-your-device-in-finder)
  - [Copy files](#copy-files)
  - [Rename and delete](#rename-and-delete)
  - [When a file changed on both sides](#when-a-file-changed-on-both-sides)
  - [See changes made on the device](#see-changes-made-on-the-device)
  - [Send files from Finder](#send-files-from-finder)
  - [Free up space on the Mac](#free-up-space-on-the-mac)
- [The menu](#the-menu)
  - [Read the menu](#read-the-menu)
  - [Device details and addresses](#device-details-and-addresses)
  - [A device's tools](#a-devices-tools)
  - [Take a screenshot or record the screen](#take-a-screenshot-or-record-the-screen)
  - [Install an app](#install-an-app)
  - [Send a file from the menu](#send-a-file-from-the-menu)
  - [Watch the device's log](#watch-the-devices-log)
  - [Forward a port](#forward-a-port)
  - [Open a shell in Terminal](#open-a-shell-in-terminal)
- [Troubleshooting](#troubleshooting)
  - [The device does not show up](#the-device-does-not-show-up)
  - [Device messages](#device-messages)
  - [USB debugging messages](#usb-debugging-messages)
  - [Wi-Fi and network messages](#wi-fi-and-network-messages)
  - [Messages in Finder](#messages-in-finder)
  - [Send to and Send File messages](#send-to-and-send-file-messages)
  - [App install messages](#app-install-messages)
  - [Screenshot and recording messages](#screenshot-and-recording-messages)
  - [Port forwarding and log messages](#port-forwarding-and-log-messages)
  - [Ferry's helper and settings](#ferrys-helper-and-settings)
  - [Remove Ferry](#remove-ferry)
- [About Ferry](#about-ferry)
  - [Updates](#updates)
  - [Privacy](#privacy)
  - [Uninstall](#uninstall)

## Install

Download Ferry from the [latest release](https://github.com/krisarmstrong/ferry/releases/latest), move **Ferry** to the **Applications** folder and open it. After that, Ferry keeps itself up to date (see **Updates**).

Ferry runs in the menu bar. It has no Dock icon and no main window. Until its helper answers, the menu shows **Checking…**.

## Getting started

### What Ferry does

Ferry shows Android devices as locations in Finder. It runs in the menu bar and has no Dock icon.

The first time Ferry opens, it starts a small helper that talks to your devices. The helper keeps running after you quit the menu, so devices stay in Finder.

Over a cable, Ferry uses the device's file transfer mode. With USB debugging on, or over Wi-Fi, it uses ADB, which is faster and adds tools such as screenshots and app installs.

### Turn on Ferry in Finder

macOS asks you to allow Ferry's locations in Finder. Until you do, the menu shows **Turn on Ferry in Finder** once a device has been connected.

1. Click the Ferry icon in the menu bar.
2. Click **Open System Settings**.
3. In Login Items & Extensions, turn on Ferry under File Providers.

You only do this once.

### Connect your first device

1. Unlock the device and connect it to the Mac with a USB cable.
2. On the device, choose **Transfer files**.
3. Look for the device in Finder's sidebar, under Locations.

The steps differ a little by model. **How to Connect** shows them for yours.

In the app, **How to Connect** opens the setup guide.

## Connecting

### Connect a network tester

For the LinkRunner 10G, EtherScope nXG and LinkRunner 100G.

1. Connect a USB-C cable to the **USB-C port on the left side** of the unit and to the Mac.
2. On the unit: **Settings** (bottom of the Home screen) → **Connected devices** → **USB**.
3. Tap **Transfer files**.

The device appears in Finder once it shares files.

In the app, **How to Connect** opens the setup guide.

### Connect an Android phone

Unlock the phone first. Its storage stays hidden while it is locked.

In the app, **How to Connect** opens the setup guide.

#### Android 8 or 9

1. Unlock the phone and connect it to the Mac with a USB cable. Its storage stays hidden while it is locked.
2. Pull down the notification shade and tap **USB charging this device**.
3. Tap **Transfer files**.

#### Android 10 or newer

1. Unlock the phone and connect it to the Mac with a USB cable. Its storage stays hidden while it is locked.
2. Pull down the notification shade and tap **Charging this device via USB**.
3. Under **USB preferences**, choose **File transfer**. Or open **Settings** → **Connected devices** → **USB**.

### Turn on USB debugging

With USB debugging on, Ferry serves the device over ADB, which is faster than file transfer and adds more tools. File transfer keeps working without it.

Menu names vary a little between phone makers. Look for Developer options and the USB debugging switch.

In the app, **How to Turn On USB Debugging** opens the USB debugging steps.

#### LinkRunner 10G, LinkRunner 100G or EtherScope nXG

1. Ask NetAlly to enable ADB on the tester.
2. After that, on the tester: **Settings** → **System** → **About tester**. Tap **Build number** until developer mode is on.
3. Go to **Settings** → **System** → **Developer options** and turn on **USB debugging**.
4. With the USB-C cable connected to the Mac, turn **USB debugging** off and on again. The tester offers ADB only after this.
5. On the device, tick **Always allow from this computer** and tap **OK**.

If the device accepts ADB over the network, use **Connect by Address…**.

#### Android 8 or 9

1. Unlock the phone and connect it to the Mac with a USB cable. Its storage stays hidden while it is locked.
2. Open **Settings** → **System** → **About phone** and tap **Build number** until developer mode is on.
3. Open **Settings** → **System** → **Developer options** and turn on **USB debugging**.
4. On the device, tick **Always allow from this computer** and tap **OK**.

If the device accepts ADB over the network, use **Connect by Address…**.

#### Android 10 or newer

1. Unlock the phone and connect it to the Mac with a USB cable. Its storage stays hidden while it is locked.
2. Open **Settings** → **About phone** and tap **Build number** until developer mode is on.
3. Open **Settings** → **System** → **Developer options** and turn on **USB debugging**.
4. On the device, tick **Always allow from this computer** and tap **Allow**.

If the device accepts ADB over the network, use **Connect by Address…**.

### Get adb

Ferry needs adb, from Google's Android platform tools, for USB debugging and Wi-Fi. File transfer works without it.

If adb is already on this Mac, from Homebrew or Android Studio, Ferry uses it. If not, the menu shows **adb isn't on this Mac**, and Ferry can download it from Google for you, once. That needs an internet connection.

1. Click **Get Android Platform Tools…** in that line.
2. Read Google's Android SDK License and click **Accept**.
3. Ferry downloads the platform tools from Google, checks that they are the release it expects and that adb is signed by Google, and keeps only adb and its notices.

Ferry keeps adb in ~/Library/Application Support/Ferry/platform-tools, and records that you accepted the license, and when. When a Ferry update needs a newer adb, Ferry downloads it the same way; if Google has changed the license, Ferry asks you to accept it again first. An adb you installed yourself works too, and Ferry prefers its own copy when both are present.

### Allow this Mac on the device

The first time a device meets this Mac over ADB, it asks whether to allow USB debugging. Ferry can't use ADB until you allow it.

Until then, the device shows **Waiting for Allow** in the menu, with **Allow USB debugging on the device** under it. Over the network, the menu shows **Waiting for you to allow this Mac on** and the address.

1. Unlock the device.
2. Tick **Always allow from this computer**, so it does not ask again.
3. Tap **OK** or **Allow**.

If the prompt never appears, unplug the cable and plug it back in. On a tester, turn **USB debugging** off and on again.

### Use a device over Wi-Fi

Use over Wi-Fi suits a device already on USB debugging, such as a network tester or a phone with Android 8 to 10.

Ferry never searches the network. It connects only to addresses you give it, and to the addresses a device on USB debugging reports for itself. A device that is also on a cable is always served by the cable.

1. Connect the device to Ethernet or Wi-Fi.
2. Connect it to the Mac by cable, with USB debugging on.
3. Click the device in the menu, then **Use over Wi-Fi**.
4. Unplug the cable. Ferry still reaches the device over the network, so it stays in Finder.

Turning it on restarts ADB on the device, so Ferry refuses while the device has a transfer, a screen recording or a log running: let it finish, then try again.

### Connect by address

For a device that already accepts ADB over the network.

1. Click **Connect by Address…**. A field opens in the menu.
2. Type the device's IP address or name. Add a port after a colon if it does not use port 5555.
3. Click **Connect** or press Return.
4. If the device asks, tap **Allow** on it.

Press Escape, or click **Connect by Address…** again, to close the field.

### Pair with a code

For phones with Android 11 and newer, which pair over Wi-Fi without a cable.

1. On the device, open **Developer options** → **Wireless debugging** and choose **Pair device with pairing code**.
2. In Ferry's menu, click **Pair with Code…**. A form opens in the menu.
3. Enter the IP address and port, and the code, that the device shows.
4. Click **Pair** or press Return.

Ferry then connects to the address the device offers for connections, which is not the one it paired on.

### Remembered devices

Ferry remembers each device it connects over the network by its serial number, and connects to it again when Ferry starts and when adb restarts. A remembered device it cannot reach shows **Remembered · not nearby**: click it, then **Connect Again** to try again.

**Forget This Device** disconnects the device and forgets its addresses. Ferry no longer connects to it by itself.

#### Is this address your device?

Anyone on a network can claim a device's serial number. So when a new address answers as a device Ferry already knows, Ferry does not use it on its own: the menu asks “Is *address* your *device*?”

**Use It** connects the address and remembers it for that device. **Ignore** leaves it unused until Ferry restarts.

## Files in Finder

### Find your device in Finder

Each device appears in Finder's sidebar under Locations, and in every app's Open and Save dialogs.

A device appears in Finder only while Ferry can reach it. When it is unplugged and not on the network, locked, or not sharing files, its location leaves the sidebar. It comes back with its files when Ferry can reach it again.

A device with an SD card shows two locations: its internal storage, and the card with “SD card” after the name. If two devices of the same model are connected, each name ends with the last four characters of its serial number.

Double-click a file to open it. Ferry copies it to the Mac when you open it.

With one device location, macOS labels it with the app's name, so the sidebar says Ferry. This is normal.

### Copy files

Drag files or folders between the device and the Mac to copy them. A half-copied file never appears under its real name.

Finder shows how far each copy has got, and the Ferry menu lists copies in progress under their device.

Files over 4 GB copy to internal storage. Many SD cards cannot hold a file over 4 GB; Ferry shows an error instead of copying part of it.

A package, such as an .rtfd document or an app, can't be copied to the device: compress it into a .zip first. Symbolic links and aliases can't be copied to the device either; Finder shows an error for them.

If the device is unplugged during a copy, plug it back in and turn on file transfer. Finder finishes the copy when the device reconnects.

### Rename and delete

Rename files and make folders on the device as you would on any drive.

The device has no Trash. Finder offers **Delete Immediately**, and the file is removed from the device at once.

A folder is deleted with its contents only if Finder has shown everything in it, at every level, as it is now. If anything inside is new or changed on the device, or a folder inside was never opened, the whole folder stays and Finder puts it back. Delete it again to remove it. A folder nested more than 64 levels deep, or holding more than 100,000 items, also stays. A folder that holds a file whose name the Mac can't show stays too; delete it on the device.

A file the device changed since Finder last showed it is not deleted. Finder puts it back with the device's version.

#### Folders named like apps

A folder on the device named like an app or a document package, such as Tool.app or Notes.rtfd, shows in Finder as an app or a document, because macOS goes by the name. Android's own app folders count too: Android/data/com.example.app reads as an app. It is read-only on the Mac, with everything in it: edit it on the device, or copy it to the Mac. Something put inside one stays on the Mac, and Finder shows an error for it. Saving one from a Mac app can leave a copy beside it, such as Notes 2.rtfd, which Finder marks with an error, with the edit only on the Mac: copy it to the Mac to keep it. A folder can't be renamed to such a name. To remove one, delete it on the device, or delete the folder that holds it; Finder may put that folder back once, so delete it again.

### When a file changed on both sides

If a file changed on the device after the Mac read it, Ferry keeps the device's version and saves yours beside it as **name (conflict from Mac)**.

Ferry never replaces a file the device changed without you seeing it.

### See changes made on the device

How quickly Finder shows a change made on the device depends on how Ferry reaches it.

Ferry watches the 32 folders Finder showed most recently on each device. A change in a folder you have not opened shows up when you open it. While a copy to or from the device runs, Ferry checks for changes again once it ends.

- **USB debugging or Wi-Fi**: Changes show up in Finder within a few seconds, and within about 30 seconds at most.
- **File transfer**: New and deleted files show up within about 30 seconds. A file changed in place or renamed on the device needs **Refresh**.

**Refresh** in the Ferry menu (⌘R while the menu is open) shows every change at once.

### Send files from Finder

Control-click files on the Mac and choose **Send to** and the device. Ferry copies them into the Download folder on the device's internal storage. Ferry's button in the Finder toolbar has the same menu once you add it with **View** → **Customize Toolbar**.

If Download already has a file with the same name, Ferry keeps it and saves yours beside it as **name (conflict from Mac)**. Sending never replaces a file.

When every selected file is an .apk and Ferry reaches the device over ADB (with USB debugging on, or over Wi-Fi), the menu also has **Install on** the device, which installs the apps as Install App… does.

A notification says when the files are on the device or the app is installed, or why not.

#### Turn on Send to

1. To turn on this menu, open System Settings, then **General** → **Login Items & Extensions**.
2. Under Extensions, find Ferry's Finder extension and turn it on.

### Free up space on the Mac

Control-click a file you opened and choose **Remove Download**. The file stays on the device.

## The menu

### Read the menu

The menu has a header with **Refresh**, then any problem that needs you, then your devices, then **Connect by Address…** and **Pair with Code…**, then **Open at Login**, **Check for Updates…**, **Help** and **Quit Ferry**.

Every device starts closed each time the menu opens. Click a device to see its details and what you can do with it, and click it again to close it. One device is open at a time, and it stays open while the menu is.

- **Ready**: The device is sharing files and is in Finder. Under its name the menu shows how Ferry reaches it and the free space, such as USB · 21 GB free, or its address over Wi-Fi.
- **Not sharing files**: File transfer is off or the device is locked. Choose **Transfer files** on the device, then **Refresh**.
- **Waiting for Allow**: USB debugging is on, but this Mac is not allowed yet. Tap **OK** or **Allow** on the device.
- **Ejected**: You ejected the device. It stays out of Finder until you click **Mount**, choose **Refresh**, or unplug it and plug it back in.
- **In use by another app**: Another app has the device. Quit that app, then click **Check Again**.
- **Can't open**: The device reported an error. Click **Check Again**, or unplug it and plug it back in.
- **Checking…**: Ferry is waiting for its helper to answer, for example just after Ferry opens.
- **Remembered · not nearby**: A device Ferry connects over the network that it can't reach now.

#### Menu items

- **Refresh**: Press ⌘R while the menu is open. Shows every change made on the device in Finder at once, including files changed in place or renamed in file transfer mode, mounts every device you ejected, and checks again a device that is not sharing files. While the menu is open, Ferry also checks for devices every 2 seconds.
- **Open at Login**: Starts Ferry when you log in. A checkmark shows it is on. **Needs approval in System Settings** means macOS is waiting for you to allow it there.
- **Check for Updates…**: Looks for a newer Ferry now. Ferry also looks once a day by itself. See **Updates**.
- **Help**: Opens this window. Press ⌘? while the menu is open. Here, ⌘F goes to the search field, Return opens the best match, and ⌘[ and ⌘] step through the topics. A **?** beside a problem in the menu opens its entry here.
- **Quit Ferry**: Closes the menu. The helper keeps running, so devices stay in Finder.

### Device details and addresses

An open device lists its network ports with their IPv4 addresses, then its Android version and battery, such as Android 8.1.0 · Battery 87%. For a model Ferry knows, every port is listed by the name on the unit, with Not connected for one that has no address. Ferry only reads them, when you open the device and every 10 seconds while the menu stays open.

Click an address to copy it; the line shows Copied for a moment. Option-click an address to copy everything the device reports: model, Android version, build, serial number, battery, every address on every port including IPv6, and storage. The line shows Copied All for a moment.

Details need USB debugging or Wi-Fi.

### A device's tools

Under an open device, its tools sit in groups divided by thin lines. A device on file transfer shows More Tools with USB Debugging… instead of the ADB tools.

- **Take Screenshot, Record Screen**: Capture the device's screen.
- **Send File…, Install App…**: Copy files into Download, or install an app.
- **Logcat, Port Forwarding, Open in Terminal**: Developer tools.
- **Use over Wi-Fi, Forget This Device, Eject**: Connection and Finder.

#### Rows that depend on the state

- **Eject**: Removes a ready device from Finder and releases it; it then shows **Ejected**. Changes that had not reached the device are saved to a folder on the Mac, and the menu offers **Reveal in Finder**. Deletes and renames that had not reached the device are dropped, so the device keeps those files under their old names.
- **Mount**: For an ejected device: puts it back in Finder.
- **Check Again**: For a device in use by another app, or one that can't open: tries it again.
- **How to Turn On File Transfer**: For a device not sharing files: opens the steps for it.
- **More Tools with USB Debugging…**: Opens the steps that turn on USB debugging.

### Take a screenshot or record the screen

Click **Take Screenshot** to save what the device's screen shows. Click **Record Screen** to record it, for up to three minutes; the menu shows how long it has been recording, and **Stop Recording** ends it.

Ferry turns the device's screen on before a screenshot or a recording, so a screen that was off is not captured black. A recording of a screen that does not change has a single frame.

Ferry saves them in Documents, in Ferry, then a folder for each device with Screenshots and Screen Recordings in it, named like macOS's own, such as Screenshot LinkRunner-100G 2026-11-18 at 17.09.27.png, and shows them in Finder. macOS asks whether Ferry may use Documents the first time it saves one. It never replaces a file. A recording waits on the device until Ferry has saved it, even if you quit Ferry meanwhile; Ferry then removes it from the device.

If Ferry can't save a recording, the menu shows Recording couldn't be saved: Choose Folder… saves it where you pick, and Discard deletes it from the device. Record Screen returns once it is saved or discarded. An ejected device keeps its recording until Ferry serves it again.

### Install an app

Click Install App… and choose an .apk file, or drag one .apk onto the device in the menu. Ferry checks that the file is an Android app, copies it to the device and installs it, replacing an older version of the same app. The menu shows how far the copy has got, then says when the app is installed.

Click **Cancel** to stop while the app is still being copied. Once the device is installing it, the install finishes.

If the device refuses the app, the menu says why, for example that a newer version is installed or that the app needs a newer version of Android. Ferry removes its copy of the app from the device either way.

### Send a file from the menu

Click **Send File…** under a device and choose files. Ferry copies them into the device's Download folder, as **Send to** does in Finder.

The menu says when they are there, or why not.

### Watch the device's log

Click Logcat to watch the device's log in a window of its own. Ferry keeps the newest 50,000 lines. Level shows lines at that level and above, and Filter shows the lines that contain your text, whatever its case. Pause freezes the window while lines keep arriving, and Resume catches up. Clear empties it.

Save… writes the lines that match the filters to a plain text file where you choose. The log stops when you close the window or the device goes away.

### Forward a port

Port forwarding sends connections to a port on this Mac to a port on the device.

If the port on this Mac is already in use, adb's message shows under the ports. Ferry lists only the TCP forwards adb holds for this device.

1. Click **Port Forwarding** under the device. It opens in place and lists each forward as Mac 8080 → Device 80.
2. Type the port on this Mac (1024 or higher) and the port on the device.
3. Click **Add** or press Return.

The remove button beside a forward ends it.

### Open a shell in Terminal

Click Open in Terminal for a shell on the device (adb shell) in Terminal. Ferry needs adb for this, and says so if it can't find it. Nothing on the device changes unless you type a command that changes it.

## Troubleshooting

### The device does not show up

1. Try another cable. Some carry power only.
2. Unlock the device.
3. Turn on file transfer on the device.
4. Check that Ferry is on under File Providers in Login Items & Extensions.
5. Choose **Refresh** in the Ferry menu.

In the app, **How to Turn On File Transfer** opens the setup guide.

#### An app or script from the device does not open at once

Files copied from a device, and folders on it named like an app or a document package, are marked as downloaded, so macOS checks an app or script with Gatekeeper before it first opens, as it does for one from the internet.

### Device messages

What the menu says about a connected device, and what to do.

**No device connected**

No device is connected and sharing files.

Connect the device and choose **Transfer files** on it.

**Choose Transfer files on the device.**

The device is connected but is not sharing files, or no device has shared files yet.

Unlock the device and choose **Transfer files** on it.

**Not sharing files**

File transfer is off or the device is locked.

Unlock the device and choose **Transfer files** on it, then choose **Refresh**. You do not need to replug the cable.

**The device is not sharing files.**

The device locked or turned off file transfer during the task.

Unlock the device and choose **Transfer files** on it, then try again.

**In use by another app**

Another Mac app has the device open, so Ferry can't reach it.

Quit Image Capture, Preview, Android File Transfer, MacDroid or OpenMTP, then click **Check Again**.

**Quit Image Capture or Android File Transfer, then try again.**

Another Mac app has the device open.

Quit Image Capture, Preview, Android File Transfer, MacDroid or OpenMTP, then click **Check Again**.

**Another app is using the device. Quit Image Capture or Android File Transfer.**

Another Mac app has the device open, so Ferry can't reach it.

Quit Image Capture, Preview, Android File Transfer, MacDroid or OpenMTP, then click **Check Again**.

**Can't open**

The device reported an error when Ferry opened it.

Click **Check Again**, or unplug the device and plug it back in.

**The device reported an error.**

The device refused the request without saying why.

Try again. If it keeps failing, unplug the device, plug it back in and click **Check Again**.

**The device was disconnected.**

The device went away during the task: the cable came out, it went to sleep, or it left the network.

Reconnect the device and try again.

**The device reports no storage.**

The device shares no storage, which happens while it is locked.

Unlock the device and choose **Refresh**.

**The device does not support this: ….**

The device can't do what was asked. The rest of the message says what.

Do it another way, for example on the device itself.

**Error: …**

Something failed on the device, the Mac or the connection. The rest of the message says what.

Try again. If it keeps failing, unplug the device, plug it back in and click **Check Again**.

**Cancelled.**

The task stopped before it finished, usually because you cancelled it.

Start it again if you still need it.

**Ferry can't watch USB for devices, so it looks for them every 30 seconds.**

macOS did not let Ferry watch for devices being plugged in.

Nothing to do: devices still appear, a little later. Restart the Mac if it stays.

**Unsent changes were saved to …**

You ejected the device before some changes reached it. macOS kept those files in a folder on the Mac. Deletes and renames that had not reached the device were dropped.

Click **Reveal in Finder**, then copy the files back onto the device once it is mounted again.

**…: changes wait to be sent. Reconnect it to finish.**

The device went away, or Ferry can no longer reach it, before some changes reached it. Its location left Finder, so the files that wait are not shown there. They stay on the Mac. An SD card has a location for each way Ferry reaches the device, so changes made on the card over a cable wait for the cable, even while the card shows over the network.

Reconnect the device the same way as before, by cable or over the network. Its location comes back to Finder and the changes are sent; the line goes once they are.

### USB debugging messages

Messages about ADB, adb and allowing this Mac.

**Waiting for Allow**

USB debugging is on, but this Mac is not allowed on the device yet.

Unlock the device, tick **Always allow from this computer** and tap **OK** or **Allow**.

**Allow USB debugging on the device**

The device is asking whether to allow this Mac.

Unlock the device, tick **Always allow from this computer** and tap **OK** or **Allow**.

**adb isn't on this Mac**

Ferry found no adb, so it can use file transfer only.

Click **Get Android Platform Tools…** and accept Google's license: Ferry downloads adb once. Installing adb any other way also works, for example Homebrew's android-platform-tools, which downloads the same file from Google, and Ferry picks up an installed adb on its own. If both are present, Ferry prefers its own copy and never disturbs a running adb server.

**Couldn't download adb. Ferry needs an internet connection once.**

Ferry could not reach Google's download server, or the server did not send the file.

Connect to the internet and click **Try Again**. Without a connection, install adb another way, for example with Homebrew: Ferry picks up an installed adb on its own.

**The download didn't pass Ferry's checks, so Ferry deleted it.**

The file was not the release Ferry expects, could not be read, or its adb was not signed by Google. Ferry never runs an adb it has not checked.

Click **Try Again**. If it fails again, something on your network may be changing downloads: try another network.

**Ferry couldn't save adb in its folder.**

Ferry could not write to ~/Library/Application Support/Ferry/platform-tools: the Mac may be full, or the folder locked or owned by another user.

Free some space on the Mac, or remove that folder if another user owns it, then click **Try Again**.

**Google changed the Android SDK License**

Ferry shows a newer text of Google's license than the one you accepted. Ferry keeps using the adb it has until you accept it.

Click **Review License…** and accept it. If this version of Ferry needs a newer adb, Ferry then downloads it.

**adb isn't running**

adb is installed but its server is not answering.

Click **Check Again**. If that does not help, quit other apps that use adb, such as Android Studio, then click **Check Again**.

**This needs USB debugging. Turn it on, then try again.**

This tool works only over ADB, and the device is on file transfer.

Turn on USB debugging on the device, then try again.

**Ferry can't find adb. Get it from the Ferry menu, then try again.**

This tool runs adb, and Ferry can't find it on this Mac.

In the Ferry menu, click **Get Android Platform Tools…**, then try again.

**Ferry couldn't open Terminal.**

macOS did not let Ferry open Terminal, or Terminal is missing.

Open Terminal once yourself, then try again. If macOS asks whether Ferry may control Terminal, allow it.

### Wi-Fi and network messages

Messages from Use over Wi-Fi, Connect by Address, Pair with Code and remembered devices.

**Waiting for you to allow this Mac on …**

A device on your network is asking whether to allow this Mac.

Tap **Allow** on the device.

**Tap Allow on the device to finish connecting.**

The device answered and is asking whether to allow this Mac.

Tap **Allow** on the device.

**Ferry knows this device at another address. Confirm the new one in the menu.**

A new address answered as a device Ferry already knows, and Ferry will not use it until you say so.

Click the address in the menu and choose **Use It** if it is your device, or **Ignore**.

**The device has no network address. Connect it to Ethernet or Wi-Fi first.**

The device is not on Ethernet or Wi-Fi.

Connect the device to Ethernet or Wi-Fi, then click **Use over Wi-Fi** again.

**adb isn't available. Use the adb line at the top of the menu.**

Network connections need adb, and Ferry has none or its server is not answering.

Click **Get Android Platform Tools…** or **Check Again** at the top of the menu, then try again.

**Connect the device with a cable and allow USB debugging first.**

Use over Wi-Fi starts from a device Ferry serves over USB debugging.

Connect the device by cable, allow this Mac on it, then try again.

**Ferry has no address for this device. Connect it by address.**

Ferry has never reached this device over the network.

Click **Connect by Address…** and type its address.

**Paired, but the device isn't offering a connection. Check Wireless debugging is on.**

Pairing worked, but the device stopped offering a connection, usually because Wireless debugging turned off.

On the device, turn on **Wireless debugging**, then click **Connect Again**.

**That address belongs to another device.**

The address answered as a different device from the one you chose.

Check the address on the device and try again.

**The device didn't say which device it is, so Ferry disconnected it.**

The device answered without a serial number, so Ferry could not tell it from others.

Connect the device by cable once, then try again.

**Use the IP address the device shows under Pair device with pairing code.**

Pairing needs the address from the pairing screen, which has its own port.

Copy the IP address and port from **Pair device with pairing code** on the device.

**That address changed. Check the menu and try again.**

The address changed after the menu showed it.

Open the menu again and choose from what it shows now.

**Ferry is using this device. Wait for its transfers, screen recording and log to finish, then try again.**

Turning on ADB over Wi-Fi restarts ADB on the device, which would stop a transfer, a screen recording or a log.

Let them finish, then try again.

**adb: …**

adb refused the request. The rest of the message is adb's reason.

Check the address and that the device is on the network, then try again.

**Remembered · not nearby**

Ferry knows the device but can't reach it on the network now.

Connect the device to the network, click it in the menu, then **Connect Again**.

### Messages in Finder

Finder shows these when a copy, rename or delete on the device does not work.

**Connect the device and choose Transfer files to see its files.**

Finder shows this in a device's location while the device is not connected or not sharing files.

Connect the device and choose **Transfer files** on it.

**Packages and app bundles can’t be copied to the device. Compress it into a .zip first.**

A package is one item on the Mac but a folder on the device, so Ferry does not copy it.

Control-click it, choose **Compress**, and copy the .zip instead.

**Symbolic links and aliases can’t be copied to the device.**

The device has no links or aliases.

Copy the original file instead.

**A folder on the device can’t take a package name, such as .app or .rtfd: macOS would open it as an app or a document.**

macOS would show a folder with that name as an app or a document.

Choose a name without a package extension, such as .app or .rtfd.

**Folders named like an app or a document package, and what they hold, can’t be changed from this Mac. Change them on the device.**

macOS shows such a folder as an app or a document, so Ferry keeps it read-only.

Change it on the device, or copy it to the Mac.

**The device does not support ….**

The device can't do what Finder asked, such as moving a file in one step.

Copy the file to its new place, then delete the original.

**The device saved “…” as “…”.**

The device changed the name, for example because it cannot store some characters.

Use the name the device chose, or rename it with characters the device accepts.

**The device sent … bytes of a file it lists as … bytes.**

The file arrived with a different size than the device listed, so the copy is not complete.

Choose **Refresh**, then open the file again.

**The device stored … bytes where … were sent.**

The device kept a different size than Ferry sent, so the copy is not complete.

Check the device has free space, then copy the file again.

**“…” holds folders nested more than … deep, which Ferry does not delete.**

Ferry does not delete a folder nested more than 64 levels deep.

Delete it on the device.

**Unexpected response from the Ferry agent.**

Ferry's helper answered in a way the Finder extension does not expect, which can happen right after an update.

Quit Ferry from the menu and open it again from Applications.

### Send to and Send File messages

The notification or menu line says which file failed, then why. Look up the reason here too.

**Couldn’t send “…” to …**

The file did not reach the device. The next line says why.

Fix what the next line says, then send it again.

**Couldn’t send … files to …**

None of the files reached the device. The next line says why for one of them.

Fix what the next line says, then send them again.

**Sent … of … to …**

Some files reached the device and some did not. The next line names one that did not, and why.

Fix what the next line says, then send the rest again.

**“…” wasn’t sent. …**

The file named did not reach the device. The reason follows.

Fix the reason, then send it again.

**Also not sent: ….**

More files failed besides the one named.

Fix the reason given, then send them again.

**Couldn’t install “…” on …**

The app did not install. The next line says why.

Fix what the next line says, then install it again.

**Couldn’t install … apps on …**

None of the apps installed. The next line says why for one of them.

Fix what the next line says, then install them again.

**Installed … of … on …**

Some apps installed and some did not. The next line names one that did not, and why.

Fix what the next line says, then install the rest again.

**“…” wasn’t installed. …**

The app named did not install. The reason follows.

Fix the reason, then install it again.

**Also not installed: ….**

More apps failed besides the one named.

Fix the reason given, then install them again.

**Only files can be sent.**

You chose something that is not a regular file.

Choose files. To copy a folder, drag it into the device's location in Finder.

**Folders can’t be sent from this menu. Copy the folder into the device’s location in Finder, or compress it into a .zip first.**

Send to sends files only.

Drag the folder into the device's location in Finder, or compress it into a .zip first.

**The device can’t store a file with that name.**

The name has characters the device's storage does not allow.

Rename the file on the Mac, then send it again.

**The device doesn’t have enough free space.**

The device's storage is full.

Free up space on the device, then try again.

**The device has a file named Download where its Download folder should be. Rename or remove it on the device, then try again.**

Ferry sends into Download, and a file on the device has that name.

Rename or remove that file on the device, then try again.

**The file can’t be read.**

Ferry could not read the file on the Mac, for example because of its permissions.

Check that you can open the file, then try again.

**The file is too large for the device’s storage.**

The storage cannot hold a file this large. Many SD cards stop at 4 GB.

Compress or split the file, or copy it to internal storage.

**This Mac doesn’t have enough free space to copy the file.**

Ferry needs room on the Mac for the copy.

Free up space on the Mac, then try again.

### App install messages

Install App…, Install on and dropping an .apk on a device can end with these.

**That file isn't an Android app (.apk).**

The file does not hold an Android app, even if its name ends in .apk.

Choose a real .apk file. A split app (.apks or .xapk) can't be installed this way.

**That app is larger than 4 GB.**

Ferry installs apps up to 4 GB.

Install it another way, such as from an app store on the device.

**The app is already installed.**

The device already has this app.

Nothing to do. To reinstall it, uninstall it on the device first.

**A newer version of the app is installed. Uninstall it first.**

The device has a newer version of this app than the .apk you chose.

Uninstall the app on the device, then install again. Or install a newer .apk.

**The installed app is signed differently. Uninstall it first.**

The app on the device was signed by someone else, so Android will not replace it.

Uninstall the app on the device, then install again. Its data on the device goes with it.

**The app needs a newer version of Android.**

The app needs a newer Android than the device runs.

Use a version of the app that supports this Android version.

**The app doesn't support this device's processor.**

The app is built for a different kind of processor than this device has.

Get a version of the app built for this device.

**The app is a test build, which the device won't install.**

The app is marked as a test build, which Android installs only with a developer command.

Use a release build of the app.

**Another app on the device already defines one of this app's permissions.**

An app already on the device defines a permission this app also defines.

Uninstall the other app, then install again.

**Another app on the device already uses this app's content provider.**

An app already on the device claims the same content provider.

Uninstall the other app, then install again.

**The app needs a library the device doesn't have.**

The app depends on a system library this device lacks.

Use a version of the app made for this device.

**The app couldn't be read by the device. It may be damaged or unsigned.**

The device could not read the .apk. It may be incomplete, damaged or unsigned.

Download or build the .apk again, then install it.

**The device doesn't allow installing apps over USB.**

A setting on the device blocks installs over USB.

In **Developer options**, turn on **Install via USB** if the device has it, then try again.

**The device's app verification refused the app.**

The device's app checks blocked the app.

Install apps only from sources you trust. The device's security settings may let you allow it.

**The install was cancelled on the device.**

Someone tapped Cancel on the device, or the device stopped the install.

Install again and accept the prompt on the device.

**The device doesn't have enough space for the app.**

The device's internal storage is too full to install the app.

Free up space on the device, then try again.

**Couldn't install the app: …**

The device refused the app for a reason Ferry has no plain words for. The rest of the message is the device's own reason.

Look up that reason, or check that the app suits this device.

### Screenshot and recording messages

Take Screenshot and Record Screen can end with these.

**The device didn't send a screenshot. Unlock it and try again.**

The device returned no image, which happens while it is locked.

Unlock the device and click **Take Screenshot** again.

**Ferry can't save to its folder in Documents. Allow Ferry in Privacy & Security.**

macOS is not letting Ferry write to Documents, where it saves screenshots and recordings.

Open System Settings → **Privacy & Security** → **Files & Folders**, and turn on Documents for Ferry.

**The device is already recording its screen.**

A recording is already running on the device.

Click **Stop Recording** first.

**The device isn't recording its screen.**

No recording is running, so there is nothing to stop. It may have reached its three-minute limit.

Click **Record Screen** to start a new one.

**The device didn't record its screen.**

The device's screen recorder stopped without a recording.

Unlock the device and try again.

**The device didn't record its screen: …**

The device's screen recorder failed. The rest of the message is the device's own reason.

Unlock the device and try again. Some screens, such as protected video, can't be recorded.

**The device sent more than a recording can be, so Ferry deleted it.**

The file the device sent was larger than a three-minute recording can be, so Ferry did not keep it.

Record again.

**The recording stopped arriving. It's still on the device: choose a folder, or discard it.**

The recording stopped coming from the device before Ferry saved it.

Click **Choose Folder…** to save it, or **Discard** to delete it from the device.

**The recording is still being finished. Try again in a moment.**

Ferry is still saving the last recording.

Wait until the menu stops showing **Saving recording…**, then try again.

**Recording couldn't be saved**

Ferry could not save the recording in Documents. It is still on the device.

Click **Choose Folder…** to save it where you pick, or **Discard** to delete it.

**Ferry's helper couldn't start copying the recording.**

Ferry's helper could not make the file to copy the recording into.

Check the Mac has free space, then click **Choose Folder…** again.

### Port forwarding and log messages

**Ports on this Mac start at 1024.**

Ports below 1024 on a Mac need administrator rights.

Type a port from 1024 to 65535.

**Use a port from 1024 to 65535 on this Mac and from 1 to 65535 on the device.**

One of the ports is missing or out of range.

Type a Mac port from 1024 to 65535 and a device port from 1 to 65535.

**adb couldn't forward the port: …**

adb refused the forward. The rest of the message is adb's reason. Often the port on this Mac is already in use.

Choose another port on this Mac, or quit the app that uses it.

**That forward is already gone.**

adb removed the forward already, for example because the device disconnected.

Nothing to do. Add it again if you need it.

**The device ended the log.**

The device stopped sending its log, for example because it restarted.

Close the window and click **Logcat** again.

**— Lines skipped: …. The log came faster than Ferry could show it. —**

The log came faster than Ferry could show it, so some lines were left out.

Set **Level** or **Filter** to show fewer lines.

**Couldn't save the log: …**

Ferry could not write the file. The rest of the message says why.

Choose another folder, or check there is free space, then click **Save…** again.

### Ferry's helper and settings

Messages about Ferry itself.

**Turn on Ferry in Finder**

Ferry's locations are all off in System Settings.

Click **Open System Settings** and turn on Ferry under File Providers.

**Allow Ferry's helper**

macOS is not letting Ferry's helper run.

Click **Open System Settings** and turn on Ferry under Allow in the Background.

**macOS can't find Ferry's helper**

macOS has lost track of Ferry's helper, often after Ferry moved.

Click **Open System Settings** and turn on Ferry under Allow in the Background. If it is missing, move Ferry to Applications and open it again.

**Ferry's helper is not responding. Quit Ferry and open it again.**

Ferry's helper stopped answering.

Quit Ferry from the menu and open it again from Applications.

**Ferry's helper didn't answer in time. Try again in a moment.**

Ferry's helper is busy or stuck.

Wait a moment and try again. If it keeps happening, quit Ferry and open it again.

**Ferry was updated. Quit and reopen Ferry.**

A newer Ferry replaced this one while it was running.

Click **Relaunch**.

**Ferry's helper couldn't read the request.**

The helper got a request it could not read, which can happen right after an update.

Quit Ferry from the menu and open it again from Applications.

**Ferry's helper doesn't take this request from here.**

A part of Ferry asked for something only another part may ask, which points to a mixed or damaged install.

Install Ferry again, then open it.

**Could not change Open at Login.**

macOS did not accept the change.

Try again. Or open System Settings → **General** → **Login Items & Extensions** and change it there.

**Needs approval in System Settings**

macOS is waiting for you to allow Ferry to open at login.

Open System Settings → **General** → **Login Items & Extensions** and allow Ferry.

**Could not remove Ferry. Make sure Ferry is running, then try again.**

Ferry's helper did not answer, so its locations could not be removed.

Quit Ferry, open it again, then click **Remove Ferry…** again.

**Help isn't available**

Ferry's help is missing from the app.

Install Ferry again.

### Remove Ferry

Removes Ferry's locations from Finder, stops Ferry's helper and quits Ferry, after asking you to confirm. Files on your devices are not touched. Use it before you move Ferry to the Trash, or to start again from a clean state.

The **Remove Ferry…** button is here in Ferry Help. Ferry asks you to confirm first.

## About Ferry

### Updates

Ferry checks for a new version once a day. When there is one, it downloads it in the background and installs it the next time Ferry quits, so nothing stops while you work.

To check now, choose **Check for Updates…** in the Ferry menu. Ferry shows what is new in the release and offers to install it.

To choose yourself, turn off **Install Updates Automatically** in the Ferry menu. Ferry still checks once a day, and asks before it downloads a new version. On a managed Mac, an administrator can set the same choice with `defaults write io.github.krisarmstrong.ferry SUAutomaticallyUpdate -bool false`.

After an update, Ferry restarts its helper the first time it opens. Your devices leave Finder for a moment and come back; a copy that was running then stops, so copy it again.

Ferry installs an update only when it carries the signature of Ferry's own release key and a valid code signature. Releases are signed with the developer's Developer ID and notarized by Apple. Ferry reads the list of releases from GitHub over a secure connection.

### Privacy

Ferry has no telemetry, no analytics and no account. Your files go only between the device and your Mac. If you use ADB over Wi-Fi, Ferry talks to that device on your network and nowhere else.

Ferry connects to the internet for two things. It checks daily for updates at GitHub, where Ferry's releases are published. And it downloads adb from Google: once, when you accept Google's license, and again without asking when a Ferry update needs a newer adb under the license you accepted. Neither sends anything about you or your devices.

### Uninstall

1. In Ferry Help, under **Troubleshooting**, click **Remove Ferry…** and confirm. Your devices disappear from Finder, Ferry's helper stops, and Ferry quits. Files on your devices are not touched.
2. Drag Ferry from Applications to the Trash.
