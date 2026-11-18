import CLibMTP

/// libmtp's table of known devices, read once. Looking a device up opens nothing.
enum MTPDeviceTable {
  /// A table entry. `@unchecked`: its strings point into libmtp's static table, which is never
  /// written or freed.
  struct Entry: @unchecked Sendable {
    let raw: LIBMTP_device_entry_t
  }

  private static let entries: [UInt32: Entry] = {
    var table: UnsafeMutablePointer<LIBMTP_device_entry_t>?
    var count: Int32 = 0
    guard LIBMTP_Get_Supported_Devices_List(&table, &count) == 0, let table else { return [:] }
    var entries: [UInt32: Entry] = [:]
    for index in 0..<Int(count) {
      let entry = table[index]
      // The first entry for a vendor and product wins, as in libmtp's own detection.
      let key = UInt32(entry.vendor_id) << 16 | UInt32(entry.product_id)
      if entries[key] == nil { entries[key] = Entry(raw: entry) }
    }
    return entries
  }()

  static func entry(vendor: UInt16, product: UInt16) -> Entry? {
    entries[UInt32(vendor) << 16 | UInt32(product)]
  }

  static func contains(vendor: UInt16, product: UInt16) -> Bool {
    entry(vendor: vendor, product: product) != nil
  }

  /// libmtp's raw device for a candidate, built the way `LIBMTP_Detect_Raw_Devices` builds it but
  /// without probing the rest of the bus: a listed device gets its table entry; any other is
  /// probed alone with `LIBMTP_Check_Specific_Device` (which opens it) and, if it answers as MTP,
  /// gets the generic entry libmtp gives an unknown device. `nil` when the probe says it is not
  /// MTP.
  static func rawDevice(for device: USBDeviceRecord) -> RawDeviceRef? {
    _ = MTPDevice.libraryInitialized
    let bus = device.locationID >> 24
    if let entry = entry(vendor: device.vendorID, product: device.productID) {
      return RawDeviceRef(
        raw: LIBMTP_raw_device_t(
          device_entry: entry.raw, bus_location: bus, devnum: device.address))
    }
    guard LIBMTP_Check_Specific_Device(Int32(bus), Int32(device.address)) == 1 else { return nil }
    let generic = LIBMTP_device_entry_t(
      vendor: nil, vendor_id: device.vendorID, product: nil, product_id: device.productID,
      device_flags: 0)
    return RawDeviceRef(
      raw: LIBMTP_raw_device_t(device_entry: generic, bus_location: bus, devnum: device.address))
  }
}
