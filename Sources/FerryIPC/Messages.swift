import DeviceKit
import Foundation

/// An item's identity in a domain, assigned by the agent the first time it sees the item and kept
/// across renames and moves.
///
/// FileProvider may write identifiers to system logs, so they never carry a name: every
/// identifier is a random UUID string, except `root`. Decoding accepts nothing else.
public struct ItemID: Hashable, Sendable, Codable, RawRepresentable {
  /// The storage root, which FileProvider calls `.rootContainer`.
  public static let root = ItemID(uncheckedRawValue: "root")

  public let rawValue: String

  public init?(rawValue: String) {
    guard rawValue == Self.root.rawValue || UUID(uuidString: rawValue)?.uuidString == rawValue
    else { return nil }
    self.rawValue = rawValue
  }

  private init(uncheckedRawValue: String) {
    rawValue = uncheckedRawValue
  }

  /// A new identifier, never equal to one assigned before.
  public static func random() -> ItemID {
    ItemID(uncheckedRawValue: UUID().uuidString)
  }

  public init(from decoder: any Decoder) throws {
    let string = try decoder.singleValueContainer().decode(String.self)
    guard let id = ItemID(rawValue: string) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "invalid item identifier"))
    }
    self = id
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// An item with its identity, as the agent reports it. The root is its own parent.
public struct ProviderEntry: Sendable, Codable, Equatable {
  public let id: ItemID
  public let parent: ItemID
  public let item: RemoteItem

  public init(id: ItemID, parent: ItemID, item: RemoteItem) {
    self.id = id
    self.parent = parent
    self.item = item
  }
}

/// A file's contents version: its size and modification date as the device reports them, since
/// MTP has no content hash. FileProvider holds it as the item's content version (see
/// `encoded`), and sends it back as the base of a change, so the agent can tell whether the
/// device's file is still the one the change was made to.
public struct ContentVersion: Codable, Sendable, Hashable {
  public let size: UInt64
  /// The bit pattern of the modification date's seconds since 1970, so the version survives
  /// every encoding exactly.
  public let modifiedBits: UInt64

  public init(_ item: RemoteItem) {
    size = item.size
    modifiedBits = item.modified.timeIntervalSince1970.bitPattern
  }

  /// Whether `other` is this version: the same size, dated in the same second. MTP and ADB both
  /// date files to the second, so a version one issued matches the other's.
  public func matches(_ other: ContentVersion) -> Bool {
    size == other.size && second == other.second
  }

  private var second: Double {
    Double(bitPattern: modifiedBits).rounded(.down)
  }

  /// Reads `encoded`; anything else, such as FileProvider's before-first-sync marker, is `nil`.
  public init?(encoded: Data) {
    guard encoded.count == 16 else { return nil }
    let bytes = [UInt8](encoded)
    func word(_ offset: Int) -> UInt64 {
      bytes[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
    size = word(0)
    modifiedBits = word(8)
  }

  /// Sixteen bytes: the size, then the date's bits, both big-endian.
  public var encoded: Data {
    var data = Data()
    withUnsafeBytes(of: size.bigEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: modifiedBits.bigEndian) { data.append(contentsOf: $0) }
    return data
  }
}

/// What the agent does when a file's contents are replaced from a version the device no longer
/// has.
public enum ConflictPolicy: String, Codable, Sendable {
  /// Keeps the device's file and uploads the Mac's contents beside it as a conflict copy.
  case keepBoth
  /// Refuses with `.changedOnDevice`, for FileProvider to merge and try again.
  case fail
}

/// Whether Finder shows Ferry's locations: the user turns each File Provider domain on in System
/// Settings, and a new domain starts off.
public enum ProviderState: String, Codable, Sendable {
  /// At least one domain is turned on.
  case enabled
  /// Every domain is off: the user has a step to take.
  case disabled
  /// No domain exists yet, because no device has been ready, so there is nothing to turn on.
  case noDomains

  /// The state of domains whose `userEnabled` flags are `enabled`.
  public init(domainsEnabled enabled: [Bool]) {
    if enabled.isEmpty {
      self = .noDomains
    } else {
      self = enabled.contains(true) ? .enabled : .disabled
    }
  }
}

/// The agent's answer to `.status`.
public struct StatusReport: Codable, Sendable, Equatable {
  public let devices: [AttachedDevice]
  public let provider: ProviderState
  /// Transfers running now, oldest first.
  public let transfers: [ActiveTransfer]
  /// Network devices (`host:port`) waiting for the user to allow this Mac on them.
  public let awaitingAuthorization: [String]
  /// Whether adb can be used; `nil` until the agent has looked.
  public let adbStatus: ADBStatus?
  /// Devices with USB debugging on that wait for the user to allow this Mac on them. A device
  /// listed here may still be served another way, over file transfer.
  public let awaitingUSBDebugging: [DeviceID]
  /// Devices the agent reconnects over the network, attached or not.
  public let remembered: [RememberedDevice]
  /// New addresses for known devices, waiting for the user to confirm them.
  public let unconfirmed: [UnconfirmedAddress]
  /// Screen recordings running now.
  public let recordings: [ActiveRecording]
  /// The agent cannot watch USB for devices coming and going, so it looks for them only every
  /// 30 s (`USBWatcher`).
  public let usbWatchFailed: Bool
  /// The number of each served device's session (`DeviceHub.heldSessions()`): it changes when
  /// the device is reached again.
  public let sessions: [DeviceID: UInt64]

  public init(
    devices: [AttachedDevice], provider: ProviderState, transfers: [ActiveTransfer] = [],
    awaitingAuthorization: [String] = [], adbStatus: ADBStatus? = nil,
    awaitingUSBDebugging: [DeviceID] = [],
    remembered: [RememberedDevice] = [], unconfirmed: [UnconfirmedAddress] = [],
    recordings: [ActiveRecording] = [], usbWatchFailed: Bool = false,
    sessions: [DeviceID: UInt64] = [:]
  ) {
    self.devices = devices
    self.provider = provider
    self.transfers = transfers
    self.awaitingAuthorization = awaitingAuthorization
    self.adbStatus = adbStatus
    self.awaitingUSBDebugging = awaitingUSBDebugging
    self.remembered = remembered
    self.unconfirmed = unconfirmed
    self.recordings = recordings
    self.usbWatchFailed = usbWatchFailed
    self.sessions = sessions
  }
}

/// A request from the app or the FileProvider extension to the agent, sent as JSON.
///
/// It arrives from a sandboxed process the agent does not control. Items are named by `ItemID`,
/// which the agent resolves through its own table, so a client can only reach items the agent
/// has reported. File contents never travel as paths: `fetch`, `create` (of a file) and
/// `replaceContents` come with an open file descriptor, so the agent never opens a file the peer
/// named.
public enum AgentRequest: Codable, Sendable, Equatable {
  /// Answered with `.status`.
  case status
  /// The devices, for the Finder Sync extension's menu. Answered with `.devices`.
  case devices
  case recheck(DeviceID)
  /// Looks for `adb` again and starts its server, for a user who has just installed it. Answered
  /// with `.done`; the next `.status` shows what it found.
  case recheckADB
  /// Connects adb to a device at an address the user typed. Answered with `.wireless`.
  case connectAddress(WirelessEndpoint)
  /// Pairs with an Android 11+ device at the pairing address and code it shows, then connects to
  /// it. Answered with `.wireless`.
  case pair(WirelessEndpoint, code: PairingCode)
  /// Connects a remembered device again. Answered with `.wireless`.
  case connectWireless(DeviceID)
  /// Moves a device on USB debugging to the network as well (Android 8–10). Answered with
  /// `.wireless`.
  case enableWireless(DeviceID)
  /// Disconnects a remembered device from the network and forgets it. Answered with `.done`.
  case forgetWireless(DeviceID)
  /// The user says an unconfirmed address is the device the menu showed, sent back exactly as
  /// shown: connected, checked again, and remembered. Answered with `.wireless`.
  case confirmWireless(UnconfirmedAddress)
  /// The user says it is not. Answered with `.done`.
  case ignoreWireless(WirelessEndpoint)
  /// Installs the readable `.apk` sent with the request on a device served over ADB, replacing
  /// any installed version. `name` is the file's name, shown with the transfer's progress.
  /// Answered with `.done` once installed.
  case installAPK(DeviceID, name: String)
  /// Writes a screenshot (a PNG) into the writable file sent with the request, which the app
  /// created in the device's capture folder. Answered with `.done`.
  case screenshot(DeviceID)
  /// Records the device's screen, for up to three minutes. Answered with `.done` once the
  /// recording has ended (Stop, or the time limit); it then waits on the device, listed in the
  /// status as finished, for `.saveRecording`.
  case startRecording(DeviceID)
  /// Stops a recording. Answered with `.done`.
  case stopRecording(DeviceID)
  /// Writes a finished recording (an MP4) into the writable file sent with the request and
  /// removes it from the device. Answered with `.done`.
  case saveRecording(DeviceID)
  /// Deletes a finished recording the app will not save, from the device. Answered with `.done`.
  case discardRecording(DeviceID)
  /// Streams the device's log (`logcat -v threadtime`) to the client on the reverse channel, in
  /// batches. Answered with `.done` when it was stopped or the device ended it, and with a
  /// failure when the device was lost. One stream per device: starting another ends the first.
  /// `stream` names this stream, so a late stop for an earlier one cannot end it.
  case startLogcat(DeviceID, stream: UUID)
  /// Ends the log stream `stream` of the device, if it is still the one running. Answered with
  /// `.done`.
  case stopLogcat(DeviceID, stream: UUID)
  /// The device's TCP port forwards. Answered with `.forwards`.
  case forwards(DeviceID)
  /// Forwards a port on this Mac to one on the device. Answered with `.done`.
  case addForward(DeviceID, PortForward)
  /// Removes the forward from this Mac's `local` port. Answered with `.done`.
  case removeForward(DeviceID, local: UInt16)
  /// Reads the device's model, version, battery, addresses and storage. Answered with
  /// `.deviceInfo`.
  case deviceInfo(DeviceID)
  /// The `adb` and serial for a shell in Terminal. Answered with `.shellTarget`.
  case shellTarget(DeviceID)
  /// Copies the readable file sent with the request into `Download/` on the device's internal
  /// storage as `name`, for Send to <device> in Finder. A name the folder already has is never
  /// written over: the file goes beside it as a conflict copy. Answered with `.entry`, whose
  /// name is the one the file got.
  case sendFile(DeviceID, name: String)
  /// Lists again every folder the agent knows on the device's domains, so changes made on the
  /// device reach Finder.
  case refresh(DeviceID)
  case eject(DeviceID)
  case removeAllDomains
  case item(domain: String, id: ItemID)
  case list(domain: String, folder: ItemID)
  /// Downloads the file into the writable file sent with the request. Answered with the item as
  /// received.
  case fetch(domain: String, id: ItemID)
  /// Uploads the readable file sent with the request as `name` in `parent`, or makes a folder
  /// (sent with no file). `name` must be one path component.
  case create(domain: String, parent: ItemID, name: String, isFolder: Bool)
  case rename(domain: String, id: ItemID, to: String)
  case move(domain: String, id: ItemID, toFolder: ItemID)
  /// Replaces the file with the readable file sent with the request. `base` is the version the
  /// new contents were made from, if known; if the device's file is no longer at it,
  /// `onConflict` decides.
  case replaceContents(
    domain: String, id: ItemID, base: ContentVersion?, onConflict: ConflictPolicy)
  /// Deletes the item. A file the device changed since `base` is `.changedOnDevice`; a folder
  /// that holds anything is `.directoryNotEmpty` unless `recursive`.
  case delete(domain: String, id: ItemID, base: ContentVersion?, recursive: Bool)
  /// The changes to the domain's items since `since`, an anchor from an earlier `.changes`
  /// response; `nil` asks only for the current anchor. Feeds FileProvider's working set.
  case changes(domain: String, since: Data?)
  /// One page of every item the agent has reported in the domain, root excluded, in a stable
  /// order: the working set FileProvider enumerates after it drops its cache. `page` is the
  /// opaque `next` of the previous `.page`, or `nil` for the first.
  case workingSet(domain: String, page: Data?)
}

public enum AgentResponse: Codable, Sendable, Equatable {
  case status(StatusReport)
  case entry(ProviderEntry)
  /// Answers a `.replaceContents` with `.keepBoth` whose base the device's file no longer has:
  /// the device's item, kept as it is, with the Mac's contents beside it as a conflict copy. Its
  /// contents are not the ones sent, so the client must fetch them.
  case keptOnDevice(ProviderEntry)
  case entries([ProviderEntry])
  /// Answers `.changes`: each changed item's latest state, the items gone, and the anchor to ask
  /// from next. `expired` means `since` cannot be answered (it predates the agent process or the
  /// agent's window), so the lists are empty and the client must enumerate everything again.
  case changes(anchor: Data, updated: [ProviderEntry], deleted: [ItemID], expired: Bool)
  /// Answers `.workingSet`. `next` is `nil` on the last page.
  case page(entries: [ProviderEntry], next: Data?)
  /// Answers `.eject` and `.removeAllDomains`: where the system saved changes the removed
  /// domains had not sent to the device yet, if any.
  case removed(preserved: [URL])
  case wireless(WirelessOutcome)
  case toolFailed(ToolFailure)
  case forwards([PortForward])
  case deviceInfo(AndroidDeviceInfo)
  case shellTarget(ShellTarget)
  case devices([DeviceSummary])
  case done
  case failure(TransportError)
}
