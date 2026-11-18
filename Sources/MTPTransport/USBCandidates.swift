/// One interface of a USB device's current configuration, as the IOKit registry reports it.
public struct USBInterface: Sendable, Hashable {
  public let interfaceClass: UInt8
  public let subclass: UInt8
  public let interfaceProtocol: UInt8
  public let endpoints: UInt8
  /// A macOS driver owns the interface, so it is not an MTP interface nobody serves.
  public let hasDriver: Bool

  public init(
    interfaceClass: UInt8, subclass: UInt8, interfaceProtocol: UInt8, endpoints: UInt8,
    hasDriver: Bool = false
  ) {
    self.interfaceClass = interfaceClass
    self.subclass = subclass
    self.interfaceProtocol = interfaceProtocol
    self.endpoints = endpoints
    self.hasDriver = hasDriver
  }

  /// Android's MTP interface: vendor-specific, with bulk in, bulk out and interrupt endpoints.
  /// Its ADB interface is vendor-specific too, but has two.
  var looksLikeMTP: Bool { interfaceClass == 0xFF && endpoints == 3 }

  /// Still Image (PTP), which cameras and some MTP players use.
  var isStillImage: Bool { interfaceClass == 0x06 }

  var isVendorSpecific: Bool { interfaceClass == 0xFF }
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

  public init(
    registryID: UInt64, locationID: UInt32, address: UInt8, vendorID: UInt16, productID: UInt16,
    interfaces: [USBInterface]?, vendorName: String? = nil, productName: String? = nil
  ) {
    self.registryID = registryID
    self.locationID = locationID
    self.address = address
    self.vendorID = vendorID
    self.productID = productID
    self.interfaces = interfaces
    self.vendorName = vendorName
    self.productName = productName
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
  /// A known Android device attached without an MTP interface: file transfer is off on it.
  case notSharing
}

enum USBCandidates {
  /// Apple's vendor ID. An iPhone or iPad exposes PTP and vendor-specific interfaces, and opening
  /// one through libusb seizes it from the system, so Apple devices are never candidates.
  static let appleVendorID: UInt16 = 0x05AC

  /// Vendors whose devices are Android phones and tablets, for recognising one whose file
  /// transfer is off: it then has no MTP interface, and often a product ID outside libmtp's
  /// table. NetAlly's Android units use Google's ID.
  static let androidVendorIDs: Set<UInt16> = [
    0x0502,  // Acer
    0x0B05,  // ASUS
    0x0BB4,  // HTC
    0x0E8D,  // MediaTek
    0x0FCE,  // Sony
    0x1004,  // LG
    0x12D1,  // Huawei
    0x17EF,  // Lenovo
    0x18D1,  // Google, and NetAlly
    0x1949,  // Amazon
    0x19D2,  // ZTE
    0x1BBB,  // TCL / Alcatel
    0x22B8,  // Motorola
    0x22D9,  // OPPO
    0x2717,  // Xiaomi
    0x2A70,  // OnePlus
    0x2AE5,  // Fairphone
    0x2D95,  // vivo
    0x04E8,  // Samsung
  ]

  /// Decides from registry properties only; nothing here opens the device.
  ///
  /// Apple devices are denied first. A device with an unowned vendor-specific interface with
  /// three endpoints may be MTP; so may a device in libmtp's table with a Still Image interface.
  /// A device in the table, or from a known Android vendor, whose interfaces are all
  /// vendor-specific (or that has none) but none looks like MTP is not sharing files. Anything
  /// else, including a Still Image camera libmtp does not list, is ignored. A device not
  /// configured yet is ignored until its interfaces register.
  static func candidacy(of device: USBDeviceRecord, inTable: Bool) -> USBCandidacy {
    if device.vendorID == appleVendorID { return .ignored }
    guard let interfaces = device.interfaces else { return .ignored }
    let mtp = interfaces.contains { $0.looksLikeMTP && (inTable || !$0.hasDriver) }
    if mtp || (inTable && interfaces.contains(where: \.isStillImage)) { return .mtp }
    let android = inTable || androidVendorIDs.contains(device.vendorID)
    if android, interfaces.allSatisfy(\.isVendorSpecific) { return .notSharing }
    return .ignored
  }
}
