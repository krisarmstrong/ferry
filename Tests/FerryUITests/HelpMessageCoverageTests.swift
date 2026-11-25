import Foundation
import Testing

@testable import FerryUI

private struct CoverageCatalogEntry: Decodable {}

private struct CoverageCatalog: Decodable {
  let strings: [String: CoverageCatalogEntry]
}

/// Open in Terminal's notes when it cannot tell which adb serves the server (`ShellLaunch`).
private let shellFallbackNote =
  "Ferry couldn't tell which adb started the adb server, so this uses Ferry's own adb. "
  + "If its version differs, adb may restart the server."
private let shellFallbackNoteNamed =
  "Ferry couldn't tell which adb started the adb server, so this uses the adb in %@. "
  + "If its version differs, adb may restart the server."

/// Every error, refusal and problem Ferry can show has a Troubleshooting entry in Help, with its
/// exact words, its cause and its fix. The table lists each message by its key in the String
/// Catalog of the module that shows it, with the topic that explains it.
///
/// The catalogs of the Finder extensions, the agent and the shared text hold little besides
/// messages, so every key there must be in the table or named below as not a message: a new
/// message without Help fails here. FerryUI's catalog is mostly labels, so its messages are
/// listed by hand; the ones the code words from an error are checked case by case in
/// `HelpLinkTests`.
struct HelpMessageCoverageTests {

  private static let help = HelpContent.bundled ?? HelpContent(version: 0, categories: [])

  private static func catalogKeys(_ module: String) throws -> Set<String> {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources/\(module)/Localizable.xcstrings")
    return Set(
      try JSONDecoder().decode(CoverageCatalog.self, from: Data(contentsOf: url)).strings.keys)
  }

  /// The table and the help's messages are the same list, each message once.
  @Test func theTableIsTheHelpsMessages() {
    let messages = Self.help.topics.flatMap(\.messages).map(\.message)
    #expect(Set(Self.table.map(\.message)).count == Self.table.count)
    #expect(Set(messages) == Set(Self.table.map(\.message)))
  }

  @Test func eachMessageIsExplainedInItsTopicUnderTroubleshooting() throws {
    let troubleshooting = try #require(
      Self.help.categories.first { $0.title == "Troubleshooting" })
    let ids = Set(troubleshooting.topics.map(\.id))
    for row in Self.table {
      #expect(Self.help.topic(forMessage: row.message)?.id == row.topic, "\(row.message)")
      #expect(ids.contains(row.topic), "\(row.topic)")
    }
  }

  @Test func eachMessageIsAStringFerryShows() throws {
    var keys = Set<String>()
    for module in ["FerryUI", "FerryText", "FerryAgentCore", "FerryProviderCore", "FerrySyncCore"] {
      keys.formUnion(try Self.catalogKeys(module))
    }
    for row in Self.table {
      #expect(keys.contains(row.message), "in no catalog: \(row.message)")
    }
  }

  /// A key added to these catalogs is a message with Help, or named as not a message.
  @Test(arguments: ["FerryText", "FerryAgentCore", "FerryProviderCore", "FerrySyncCore"])
  func everyStringInTheCatalogIsCovered(module: String) throws {
    let keys = try Self.catalogKeys(module)
    let others = Self.notMessages[module] ?? []
    let covered = Set(Self.table.map(\.message))
    #expect(others.isSubset(of: keys), "\(module): \(others.subtracting(keys).sorted())")
    #expect(others.isDisjoint(with: covered))
    let missing = keys.subtracting(covered).subtracting(others)
    #expect(missing.isEmpty, "\(module) messages without Help: \(missing.sorted())")
  }

  /// Every FerryUI key is Help's own words, a message in the table, or a label listed in
  /// `FerryUILabels`: a new problem line cannot reach the menu without someone deciding.
  @Test func everyFerryUIStringIsHelpAMessageOrALabel() throws {
    let keys = try Self.catalogKeys("FerryUI")
    let help = Set(Self.help.categories.map(\.title) + Self.help.topics.flatMap(\.strings))
    let messages = Set(Self.table.map(\.message))
    let unclassified = keys.subtracting(help).subtracting(messages).subtracting(FerryUILabels.keys)
    #expect(unclassified.isEmpty, "FerryUI strings to classify: \(unclassified.sorted())")
    #expect(FerryUILabels.keys.isSubset(of: keys), "\(FerryUILabels.keys.subtracting(keys))")
    #expect(FerryUILabels.keys.isDisjoint(with: messages.union(help)))
  }

  /// Help shows each message in its exact words, with "…" for a value shown with it.
  @Test func eachMessageIsShownInItsExactWords() throws {
    for message in Self.help.topics.flatMap(\.messages) {
      let expected = message.message.replacing(/%(?:@|lld|llu)/, with: "…")
      #expect(HelpText.plain(message.wording) == expected, "\(message.message)")
      #expect(!message.cause.isEmpty && !message.fix.isEmpty, "\(message.message)")
    }
  }
}

extension HelpMessageCoverageTests {
  /// Keys in the small catalogs that are not messages: names, notices of success, menu titles.
  private static let notMessages: [String: Set<String>] = [
    "FerryText": ["Unknown device"],
    "FerryAgentCore": ["%@ – SD card", "conflict from Mac", "conflict from Mac %lld"],
    "FerryProviderCore": [],
    "FerrySyncCore": [
      "Download already had a file with that name, so it’s there as “%@”.", "Install on %@",
      "Installed %lld apps on %@", "Installed “%@” on %@", "It’s in Download.",
      "Select files to send", "Send selected files to a device", "Send to %@",
      "Sent %lld files to %@", "Sent “%@” to %@", "They’re in Download.",
    ],
  ]
}

extension HelpMessageCoverageTests {
  static let table: [(topic: String, message: String)] = [
    ("trouble-device", "No device connected"),
    ("trouble-device", "Choose Transfer files on the device."),
    ("trouble-device", "Not sharing files"),
    (
      "trouble-device",
      "The device is not sharing files. Unlock it and choose Transfer files, then try again."
    ),
    ("trouble-device", "The device was disconnected. Reconnect it, then try again."),
    ("trouble-device", "The device shows no storage. Unlock it, then try again."),
    (
      "trouble-device",
      "Ferry can't do this from the Mac on this device. Do it on the device instead."
    ),
    (
      "trouble-device",
      "Ferry couldn't finish this. Try again; if it keeps failing, reconnect the device or reopen Ferry."
    ),
    ("trouble-device", "That item is no longer on the device. Refresh, then try again."),
    (
      "trouble-device", "The device already has an item with that name. Rename one, then try again."
    ),
    ("trouble-device", "The device can't store that name. Choose another name."),
    ("trouble-device", "The device is out of space. Free some space on it, then try again."),
    (
      "trouble-device",
      "The file is too large for that storage. Use internal storage, or a smaller file."
    ),
    ("trouble-device", "The file didn't arrive complete. Try again."),
    ("trouble-device", "The device saved the file under another name. Look for it in the folder."),
    ("trouble-device", "The folder isn't empty. Delete what it holds first."),
    ("trouble-device", "The file changed on the device. Refresh, then try again."),
    ("trouble-device", "This Mac is out of space. Free some space, then try again."),
    (
      "trouble-device",
      "That folder is nested too deep to delete from the Mac. Delete it on the device."
    ),
    ("trouble-device", "That item is read-only from the Mac. Change it on the device."),
    ("trouble-device", "The folder's listing went out of date. Try again."),
    ("trouble-device", "In use by another app"),
    ("trouble-device", "Quit Image Capture or Android File Transfer, then try again."),
    (
      "trouble-device",
      "Another app is using the device. Quit Image Capture or Android File Transfer."
    ),
    ("trouble-device", "Can't open"),
    ("trouble-device", "Cancelled."),
    ("trouble-device", "Ferry can't watch USB for devices, so it looks for them every 30 seconds."),
    ("trouble-device", "Unsent changes were saved to %@"),
    ("trouble-device", "Files waiting to go back to their device: %lld"),
    ("trouble-device", "%@: changes wait to be sent. Reconnect it to finish."),
    ("trouble-adb", "Waiting for Allow"),
    ("trouble-adb", "Allow USB debugging on the device"),
    ("trouble-adb", "Unplug the cable and plug it in again to use USB debugging"),
    ("trouble-adb", "adb isn't on this Mac"),
    ("trouble-adb", "Couldn't download adb. Ferry needs an internet connection once."),
    ("trouble-adb", "The download didn't pass Ferry's checks, so Ferry deleted it."),
    ("trouble-adb", "Ferry couldn't save adb in its folder."),
    ("trouble-adb", "Google changed the Android SDK License"),
    ("trouble-adb", "adb isn't running"),
    ("trouble-adb", "This needs USB debugging. Turn it on, then try again."),
    ("trouble-adb", "Ferry can't find adb. Get it from the Ferry menu, then try again."),
    ("trouble-adb", "Ferry couldn't open Terminal."),
    ("trouble-adb", shellFallbackNote),
    ("trouble-adb", shellFallbackNoteNamed),
    ("trouble-network", "Waiting for you to allow this Mac on %@"),
    ("trouble-network", "Tap Allow on the device to finish connecting."),
    (
      "trouble-network",
      "Ferry knows this device at another address. Confirm the new one in the menu."
    ),
    (
      "trouble-network",
      "The device has no network address. Connect it to Ethernet or Wi-Fi first."
    ),
    ("trouble-network", "adb isn't available. Use the adb line at the top of the menu."),
    ("trouble-network", "Connect the device with a cable and allow USB debugging first."),
    ("trouble-network", "Ferry has no address for this device. Connect it by address."),
    (
      "trouble-network",
      "Paired, but the device isn't offering a connection. Check Wireless debugging is on."
    ),
    ("trouble-network", "That address belongs to another device."),
    ("trouble-network", "The device didn't say which device it is, so Ferry disconnected it."),
    ("trouble-network", "Use the IP address the device shows under Pair device with pairing code."),
    ("trouble-network", "That address changed. Check the menu and try again."),
    (
      "trouble-network",
      "adb had lost network access, so Ferry restarted it. Try again in a moment."
    ),
    (
      "trouble-network",
      """
      Ferry needs Local Network access to reach devices over Wi-Fi. Turn on FerryAgent (Ferry) \
      in System Settings › Privacy & Security › Local Network.
      """
    ),
    (
      "trouble-network",
      """
      Ferry is using this device. Wait for its transfers, screen recording and log to finish, \
      then try again.
      """
    ),
    (
      "trouble-network",
      "adb refused the request. Check the address and that the device is on the network, then try again. (%@)"
    ),
    ("trouble-network", "Remembered · not nearby"),
    ("trouble-finder", "Connect the device and choose Transfer files to see its files."),
    (
      "trouble-finder",
      "Packages and app bundles can’t be copied to the device. Compress it into a .zip first."
    ),
    ("trouble-finder", "Symbolic links and aliases can’t be copied to the device."),
    (
      "trouble-finder",
      """
      A folder on the device can’t take a package name, such as .app or .rtfd: macOS would \
      open it as an app or a document.
      """
    ),
    (
      "trouble-finder",
      """
      Folders named like an app or a document package, and what they hold, can’t be changed \
      from this Mac. Change them on the device.
      """
    ),
    ("trouble-finder", "The device saved “%@” as “%@”."),
    ("trouble-finder", "The device sent %llu bytes of a file it lists as %llu bytes."),
    ("trouble-finder", "The device stored %llu bytes where %llu were sent."),
    (
      "trouble-finder",
      "“%@” holds folders nested more than %lld deep, which Ferry does not delete."
    ),
    (
      "trouble-finder",
      "Ferry's helper sent an answer Ferry didn't expect. Quit and reopen Ferry, then try again."
    ),
    ("trouble-send", "Couldn’t send “%@” to %@"),
    ("trouble-send", "Couldn’t send %lld files to %@"),
    ("trouble-send", "Sent %lld of %lld to %@"),
    ("trouble-send", "“%@” wasn’t sent."),
    ("trouble-send", "Also not sent: %lld."),
    ("trouble-send", "Couldn’t install “%@” on %@"),
    ("trouble-send", "Couldn’t install %lld apps on %@"),
    ("trouble-send", "Installed %lld of %lld on %@"),
    ("trouble-send", "“%@” wasn’t installed."),
    ("trouble-send", "Also not installed: %lld."),
    ("trouble-send", "Only files can be sent."),
    (
      "trouble-send",
      """
      Folders can’t be sent from this menu. Copy the folder into the device’s location in \
      Finder, or compress it into a .zip first.
      """
    ),
    ("trouble-send", "The device can’t store a file with that name."),
    ("trouble-send", "The device doesn’t have enough free space."),
    (
      "trouble-send",
      """
      The device has a file named Download where its Download folder should be. Rename or \
      remove it on the device, then try again.
      """
    ),
    ("trouble-send", "The file can’t be read."),
    ("trouble-send", "The file is too large for the device’s storage."),
    ("trouble-send", "This Mac doesn’t have enough free space to copy the file."),
    ("trouble-install", "That file isn't an Android app (.apk)."),
    ("trouble-install", "That app is larger than 4 GB."),
    ("trouble-install", "The app is already installed."),
    ("trouble-install", "A newer version of the app is installed. Uninstall it first."),
    ("trouble-install", "The installed app is signed differently. Uninstall it first."),
    ("trouble-install", "The app needs a newer version of Android."),
    ("trouble-install", "The app doesn't support this device's processor."),
    ("trouble-install", "The app is a test build, which the device won't install."),
    ("trouble-install", "Another app on the device already defines one of this app's permissions."),
    ("trouble-install", "Another app on the device already uses this app's content provider."),
    ("trouble-install", "The app needs a library the device doesn't have."),
    ("trouble-install", "The app couldn't be read by the device. It may be damaged or unsigned."),
    ("trouble-install", "The device doesn't allow installing apps over USB."),
    ("trouble-install", "The device's app verification refused the app."),
    ("trouble-install", "The install was cancelled on the device."),
    ("trouble-install", "The device doesn't have enough space for the app."),
    (
      "trouble-install",
      "The device didn't install the app. Check that it suits this device, then try again. (%@)"
    ),
    ("trouble-capture", "The device didn't send a screenshot. Unlock it and try again."),
    (
      "trouble-capture",
      "Ferry can't save to its folder in Documents. Allow Ferry in Privacy & Security."
    ),
    ("trouble-capture", "The device is already recording its screen."),
    ("trouble-capture", "The device isn't recording its screen."),
    ("trouble-capture", "The device didn't record its screen."),
    ("trouble-capture", "The device didn't record its screen: %@"),
    ("trouble-capture", "The device sent more than a recording can be, so Ferry deleted it."),
    (
      "trouble-capture",
      "The recording stopped arriving. It's still on the device: choose a folder, or discard it."
    ),
    ("trouble-capture", "The recording is still being finished. Try again in a moment."),
    ("trouble-capture", "Recording couldn't be saved"),
    ("trouble-capture", "Ferry's helper couldn't start copying the recording."),
    ("trouble-tools", "Ports on this Mac start at 1024."),
    (
      "trouble-tools",
      "Use a port from 1024 to 65535 on this Mac and from 1 to 65535 on the device."
    ),
    ("trouble-tools", "adb couldn't forward the port: %@"),
    ("trouble-tools", "That forward is already gone."),
    ("trouble-tools", "The device ended the log."),
    ("trouble-tools", "— Lines skipped: %lld. The log came faster than Ferry could show it. —"),
    (
      "trouble-tools",
      "Ferry couldn't save the log. Choose another folder or free some space, then try again. (%@)"
    ),
    ("trouble-helper", "Turn on Ferry in Finder"),
    ("trouble-helper", "Allow Ferry's helper"),
    ("trouble-helper", "macOS can't find Ferry's helper"),
    ("trouble-helper", "Ferry's helper is not responding. Quit Ferry and open it again."),
    ("trouble-helper", "Ferry's helper didn't answer in time. Try again in a moment."),
    ("trouble-helper", "Ferry's helper has too many requests waiting. Try again in a moment."),
    ("trouble-helper", "Ferry was updated. Quit and reopen Ferry."),
    ("trouble-helper", "Ferry's helper couldn't read the request."),
    ("trouble-helper", "Ferry's helper doesn't take this request from here."),
    ("trouble-helper", "Could not change Open at Login."),
    ("trouble-helper", "Needs approval in System Settings"),
    (
      "trouble-helper",
      "Could not remove Ferry. Try again; if it keeps failing, restart the Mac and try again."
    ),
    ("trouble-helper", "Help isn't available"),
  ]
}
