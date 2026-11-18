import DeviceKit
import Foundation
import IOKit
import IOKit.usb

/// Reads USB devices from the IOKit registry. Nothing here opens a device or does USB I/O: the
/// registry holds what macOS read when the device enumerated.
public enum USBRegistry {
  /// Every USB device attached now.
  static func attached() throws(TransportError) -> [USBDeviceRecord] {
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(
      kIOMainPortDefault, IOServiceMatching(kIOUSBHostDeviceClassName), &iterator)
    guard result == KERN_SUCCESS else {
      throw .io("listing USB devices failed (IOKit error \(result))")
    }
    defer { IOObjectRelease(iterator) }
    var devices: [USBDeviceRecord] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
      if let device = record(of: service) { devices.append(device) }
      IOObjectRelease(service)
    }
    return devices
  }

  /// Whether the enumeration with this registry entry is still attached. A device that left, or
  /// enumerated again after a replug or a USB mode switch, has a new entry or none.
  static func isAttached(registryID: UInt64) -> Bool {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
    guard service != 0 else { return false }
    IOObjectRelease(service)
    return true
  }

  /// The registry ID of the device `service` stands for, if Ferry may use that device. `service`
  /// is a USB device or one of its interfaces.
  public static func candidateDevice(_ service: io_service_t) -> UInt64? {
    if IOObjectConformsTo(service, kIOUSBHostInterfaceClassName) != 0 {
      var parent: io_registry_entry_t = 0
      guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS
      else { return nil }
      defer { IOObjectRelease(parent) }
      return candidateDevice(parent)
    }
    guard let device = record(of: service),
      MTPTransport.candidacy(of: device) != .ignored
    else { return nil }
    return device.registryID
  }

  /// The registry ID of any registry entry.
  public static func registryID(of service: io_service_t) -> UInt64? {
    var id: UInt64 = 0
    return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
  }

  static func record(of service: io_service_t) -> USBDeviceRecord? {
    guard let registryID = registryID(of: service),
      let vendor: UInt16 = number(service, "idVendor"),
      let product: UInt16 = number(service, "idProduct"),
      let locationID: UInt32 = number(service, "locationID"),
      let address: UInt8 = number(service, "USB Address")
    else { return nil }
    let configuration: UInt8 = number(service, "kUSBCurrentConfiguration") ?? 0
    return USBDeviceRecord(
      registryID: registryID, locationID: locationID, address: address, vendorID: vendor,
      productID: product, interfaces: configuration == 0 ? nil : interfaces(of: service),
      vendorName: string(service, "USB Vendor Name"),
      productName: string(service, "USB Product Name"))
  }

  private static func interfaces(of device: io_service_t) -> [USBInterface] {
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var interfaces: [USBInterface] = []
    while case let child = IOIteratorNext(iterator), child != 0 {
      defer { IOObjectRelease(child) }
      guard IOObjectConformsTo(child, kIOUSBHostInterfaceClassName) != 0,
        let interfaceClass: UInt8 = number(child, "bInterfaceClass"),
        let subclass: UInt8 = number(child, "bInterfaceSubClass"),
        let interfaceProtocol: UInt8 = number(child, "bInterfaceProtocol"),
        let endpoints: UInt8 = number(child, "bNumEndpoints")
      else { continue }
      interfaces.append(
        USBInterface(
          interfaceClass: interfaceClass, subclass: subclass,
          interfaceProtocol: interfaceProtocol, endpoints: endpoints,
          hasDriver: hasDriver(child)))
    }
    return interfaces
  }

  /// Whether a driver serves the interface. A user client, such as libusb's or a browser's, is
  /// an app looking at it, not a driver.
  private static func hasDriver(_ interface: io_registry_entry_t) -> Bool {
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(interface, kIOServicePlane, &iterator) == KERN_SUCCESS
    else { return false }
    defer { IOObjectRelease(iterator) }
    while case let child = IOIteratorNext(iterator), child != 0 {
      defer { IOObjectRelease(child) }
      if IOObjectConformsTo(child, "IOUserClient") == 0 { return true }
    }
    return false
  }

  private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue()
  }

  private static func number<T: FixedWidthInteger>(_ entry: io_registry_entry_t, _ key: String)
    -> T?
  {
    guard let number = property(entry, key) as? NSNumber else { return nil }
    return T(exactly: number.uint64Value)
  }

  private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
    property(entry, key) as? String
  }
}
