import Testing

@testable import MTPTransport

struct USBCandidatesTests {
  static let mtp = USBInterface(
    interfaceClass: 0xFF, subclass: 0xFF, interfaceProtocol: 0, endpoints: 3)
  static let adb = USBInterface(
    interfaceClass: 0xFF, subclass: 0x42, interfaceProtocol: 1, endpoints: 2)
  static let ptp = USBInterface(
    interfaceClass: 0x06, subclass: 1, interfaceProtocol: 1, endpoints: 3)
  static let usbmux = USBInterface(
    interfaceClass: 0xFF, subclass: 0xFE, interfaceProtocol: 2, endpoints: 3)
  static let massStorage = USBInterface(
    interfaceClass: 0x08, subclass: 6, interfaceProtocol: 0x50, endpoints: 2)

  static func device(
    vendor: UInt16, product: UInt16, interfaces: [USBInterface]?, name: String = "Device"
  ) -> USBDeviceRecord {
    USBDeviceRecord(
      registryID: 1, locationID: 0x0021_0000, address: 3, vendorID: vendor, productID: product,
      interfaces: interfaces, vendorName: "Vendor", productName: name)
  }

  static func candidacy(_ device: USBDeviceRecord) -> USBCandidacy {
    USBCandidates.candidacy(
      of: device,
      inTable: MTPDeviceTable.contains(vendor: device.vendorID, product: device.productID))
  }

  @Test func iPhoneIsNeverACandidate() {
    let iPhone = Self.device(
      vendor: 0x05AC, product: 0x12A8, interfaces: [Self.ptp, Self.usbmux, Self.mtp])
    #expect(Self.candidacy(iPhone) == .ignored)
  }

  @Test func linkRunnerIsAdmittedThroughLibmtpsTable() {
    #expect(MTPDeviceTable.contains(vendor: 0x18D1, product: 0x4EE1))
    let linkRunner = Self.device(
      vendor: 0x18D1, product: 0x4EE1, interfaces: [Self.mtp], name: "LinkRunner-100G")
    #expect(Self.candidacy(linkRunner) == .mtp)
  }

  @Test func unknownDeviceWithAnUnownedMTPInterfaceIsAdmitted() {
    #expect(!MTPDeviceTable.contains(vendor: 0x1234, product: 0x5678))
    #expect(
      Self.candidacy(Self.device(vendor: 0x1234, product: 0x5678, interfaces: [Self.mtp])) == .mtp)
  }

  @Test func unknownVendorInterfaceThatADriverOwnsIsIgnored() {
    let owned = USBInterface(
      interfaceClass: 0xFF, subclass: 0xFF, interfaceProtocol: 0, endpoints: 3, hasDriver: true)
    #expect(
      Self.candidacy(Self.device(vendor: 0x0BDA, product: 0x8153, interfaces: [owned])) == .ignored)
  }

  @Test func stillImageCameraNotInTheTableIsIgnored() {
    #expect(!MTPDeviceTable.contains(vendor: 0x04A9, product: 0x0001))
    #expect(
      Self.candidacy(Self.device(vendor: 0x04A9, product: 0x0001, interfaces: [Self.ptp]))
        == .ignored)
  }

  @Test func unconfiguredDeviceWaitsForItsInterfaces() {
    #expect(
      Self.candidacy(Self.device(vendor: 0x18D1, product: 0x4EE1, interfaces: nil)) == .ignored)
  }

  @Test func androidDeviceWithoutMTPInterfaceIsNotSharing() {
    let chargeOnly = Self.device(vendor: 0x18D1, product: 0x4EE7, interfaces: [Self.adb])
    #expect(Self.candidacy(chargeOnly) == .notSharing)
    #expect(
      Self.candidacy(Self.device(vendor: 0x18D1, product: 0x4EE1, interfaces: [])) == .notSharing)
  }

  @Test func androidVendorsOtherDevicesAreIgnored() {
    let ssd = Self.device(vendor: 0x04E8, product: 0x4001, interfaces: [Self.massStorage])
    #expect(Self.candidacy(ssd) == .ignored)
  }

  @Test func appleDeviceIsNeverNotSharing() {
    #expect(
      Self.candidacy(Self.device(vendor: 0x05AC, product: 0x12A8, interfaces: [])) == .ignored)
  }
}
