/// One interface of a USB device's current configuration, as the IOKit registry reports it.
public struct USBInterface: Sendable, Hashable {
  public let interfaceClass: UInt8
  public let subclass: UInt8
  public let interfaceProtocol: UInt8
  public let endpoints: UInt8
  /// A macOS driver owns the interface, so it is not an MTP interface nobody serves.
  public let hasDriver: Bool
  /// The interface's string descriptor (`kUSBString`), which Android sets to "MTP".
  public let name: String?

  public init(
    interfaceClass: UInt8, subclass: UInt8, interfaceProtocol: UInt8, endpoints: UInt8,
    hasDriver: Bool = false, name: String? = nil
  ) {
    self.interfaceClass = interfaceClass
    self.subclass = subclass
    self.interfaceProtocol = interfaceProtocol
    self.endpoints = endpoints
    self.hasDriver = hasDriver
    self.name = name
  }

  /// Android's MTP interface: vendor-specific, with bulk in, bulk out and interrupt endpoints.
  /// Its ADB interface is vendor-specific too, but has two.
  var looksLikeMTP: Bool { interfaceClass == 0xFF && endpoints == 3 }

  /// Still Image (PTP), which cameras and some MTP players use.
  var isStillImage: Bool { interfaceClass == 0x06 }

  var isVendorSpecific: Bool { interfaceClass == 0xFF }

  /// An interface no driver serves that says it is MTP, with MTP's shape: Android's
  /// vendor-specific 0xFF/0xFF/0x00 with three endpoints, or Still Image 6/1/1. The name is
  /// matched as libmtp's own probe matches it: containing "MTP" in any case.
  var announcesMTP: Bool {
    guard !hasDriver, let name, name.range(of: "MTP", options: .caseInsensitive) != nil else {
      return false
    }
    let android = interfaceClass == 0xFF && subclass == 0xFF && interfaceProtocol == 0
    let stillImage = interfaceClass == 0x06 && subclass == 1 && interfaceProtocol == 1
    return (android && endpoints == 3) || stillImage
  }
}

/// A USB device as the IOKit registry describes it, read without opening the device.
public struct USBDeviceRecord: Sendable, Hashable {
  /// The registry entry. A device gets a new one each time it enumerates, so it tells a replug
  /// or a USB mode switch on the same port and address from a device that stayed put.
  public let registryID: UInt64
  public let locationID: UInt32
  public let address: UInt8
  public let vendorID: UInt16
  public let productID: UInt16
  /// The current configuration's interfaces, or `nil` while the device is not configured yet:
  /// its interfaces register after the device itself.
  public let interfaces: [USBInterface]?
  public let vendorName: String?
  public let productName: String?
  /// The USB serial number string, which Android sets to `ro.serialno`.
  public let serial: String?

  public init(
    registryID: UInt64, locationID: UInt32, address: UInt8, vendorID: UInt16, productID: UInt16,
    interfaces: [USBInterface]?, vendorName: String? = nil, productName: String? = nil,
    serial: String? = nil
  ) {
    self.registryID = registryID
    self.locationID = locationID
    self.address = address
    self.vendorID = vendorID
    self.productID = productID
    self.interfaces = interfaces
    self.vendorName = vendorName
    self.productName = productName
    self.serial = serial
  }

  /// Where libusb finds the device: on Darwin its bus is the top byte of the location ID.
  var location: BusLocation {
    BusLocation(bus: locationID >> 24, address: address, registryID: registryID)
  }
}

/// What Ferry may do with a USB device, decided from its registry properties alone.
enum USBCandidacy: Sendable, Equatable {
  /// Not Ferry's: never opened, never probed, never reported.
  case ignored
  /// May speak MTP, so libmtp may open it.
  case mtp
  /// Not in libmtp's table, but an interface says it is MTP. libmtp may open it once the device
  /// has settled: its drivers may not have matched yet when it first appears (see
  /// `DeviceRegistry`).
  case probe
  /// A known Android device attached without an MTP interface: file transfer is off on it.
  case notSharing
}

enum USBCandidates {
  /// Apple's vendor ID. An iPhone or iPad exposes PTP and vendor-specific interfaces, and opening
  /// one through libusb seizes it from the system, so Apple devices are never candidates.
  static let appleVendorID: UInt16 = 0x05AC

  /// Android devices in a USB mode without file transfer that libmtp's table does not list, by
  /// vendor and product. Listed per device, not per vendor: an Android vendor also makes modems,
  /// dongles and drives, which must not show as a phone with file transfer off.
  static let chargeOnlyAndroidDevices: Set<UInt32> = [
    0x18D1_4EE7  // Google (and NetAlly units): charging only, with USB debugging
  ]

  /// Decides from registry properties only; nothing here opens the device.
  ///
  /// Apple devices are denied first. A device in libmtp's table with an MTP-shaped interface
  /// (vendor-specific with three endpoints) or a Still Image one is MTP. A device outside the
  /// table is probed only if an interface no driver owns says it is MTP (`announcesMTP`): a
  /// vendor-specific interface alone also describes GPS units, radios and lab gear, which libusb
  /// would seize.
  /// A device in the table, or in `chargeOnlyAndroidDevices`, whose interfaces are all
  /// vendor-specific (or that has none) but none looks like MTP is not sharing files. Anything
  /// else, including a Still Image camera libmtp does not list, is ignored. A device not
  /// configured yet is ignored until its interfaces register.
  static func candidacy(of device: USBDeviceRecord, inTable: Bool) -> USBCandidacy {
    if device.vendorID == appleVendorID { return .ignored }
    guard let interfaces = device.interfaces else { return .ignored }
    if inTable, interfaces.contains(where: { $0.looksLikeMTP || $0.isStillImage }) {
      return .mtp
    }
    if !inTable, interfaces.contains(where: \.announcesMTP) { return .probe }
    let product = UInt32(device.vendorID) << 16 | UInt32(device.productID)
    let android = inTable || chargeOnlyAndroidDevices.contains(product)
    if android, interfaces.allSatisfy(\.isVendorSpecific) { return .notSharing }
    return .ignored
  }
}
