import Testing

@testable import DeviceKit

struct DeviceSelectionTests {
  let first = DeviceInfo(id: DeviceID(serial: "A1"), manufacturer: "Acme", model: "One")
  let second = DeviceInfo(id: DeviceID(serial: "B2"), manufacturer: "Acme", model: "Two")

  func storage(_ description: String, device: DeviceID) -> StorageInfo {
    StorageInfo(
      id: StorageID(device: device, key: description + "|v"), description: description,
      capacity: 10, free: 5)
  }

  @Test func defaultsToFirstDevice() throws {
    #expect(
      try DeviceSelection.pickDevice(serial: nil, from: DeviceScan(devices: [first, second]))
        == first)
  }

  @Test func matchesDeviceBySerial() throws {
    #expect(
      try DeviceSelection.pickDevice(serial: "B2", from: DeviceScan(devices: [first, second]))
        == second)
  }

  @Test func noDevicesThrowsNoDeviceConnected() {
    #expect(throws: TransportError.noDeviceConnected) {
      try DeviceSelection.pickDevice(serial: nil, from: DeviceScan(devices: []))
    }
  }

  @Test func listingNoDevicesThrowsNoDeviceConnected() {
    #expect(throws: TransportError.noDeviceConnected) {
      try DeviceSelection.requireAny(DeviceScan(devices: []))
    }
  }

  @Test func listingDevicesReturnsThemAll() throws {
    #expect(
      try DeviceSelection.requireAny(DeviceScan(devices: [first, second])) == [first, second])
  }

  @Test func onlyBusyDevicesThrowsDeviceBusy() {
    let held = DeviceInfo(id: DeviceID(serial: "usb-1-2"), manufacturer: "Acme", model: "Two")
    let scan = DeviceScan(devices: [], busy: [held])
    #expect(throws: TransportError.deviceBusy) { try DeviceSelection.requireAny(scan) }
    #expect(throws: TransportError.deviceBusy) {
      try DeviceSelection.pickDevice(serial: nil, from: scan)
    }
  }

  @Test func busyDeviceDoesNotHideUsableOnes() throws {
    let held = DeviceInfo(id: DeviceID(serial: "usb-1-2"), manufacturer: "Acme", model: "Two")
    #expect(try DeviceSelection.requireAny(DeviceScan(devices: [first], busy: [held])) == [first])
  }

  @Test func unknownSerialThrowsDeviceNotFound() {
    #expect(throws: TransportError.deviceNotFound(DeviceID(serial: "ZZ"))) {
      try DeviceSelection.pickDevice(serial: "ZZ", from: DeviceScan(devices: [first]))
    }
  }

  @Test func defaultsToFirstStorage() throws {
    let list = [storage("Internal", device: first.id), storage("SD", device: first.id)]
    #expect(try DeviceSelection.pickStorage(description: nil, from: list) == list[0])
  }

  @Test func matchesStorageByDescription() throws {
    let list = [storage("Internal", device: first.id), storage("SD", device: first.id)]
    #expect(try DeviceSelection.pickStorage(description: "SD", from: list) == list[1])
  }

  @Test func noStoragesThrowsNoStorage() {
    #expect(throws: TransportError.noStorage) {
      try DeviceSelection.pickStorage(description: nil, from: [])
    }
  }

  @Test func unknownStorageThrowsStorageNotFound() {
    let list = [storage("Internal", device: first.id)]
    #expect(throws: TransportError.storageNotFound("SD")) {
      try DeviceSelection.pickStorage(description: "SD", from: list)
    }
  }
}
