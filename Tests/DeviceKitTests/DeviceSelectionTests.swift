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
    #expect(try DeviceSelection.pickDevice(serial: nil, from: [first, second]) == first)
  }

  @Test func matchesDeviceBySerial() throws {
    #expect(try DeviceSelection.pickDevice(serial: "B2", from: [first, second]) == second)
  }

  @Test func noDevicesThrowsNoDeviceConnected() {
    #expect(throws: TransportError.noDeviceConnected) {
      try DeviceSelection.pickDevice(serial: nil, from: [])
    }
  }

  @Test func unknownSerialThrowsDeviceNotFound() {
    #expect(throws: TransportError.deviceNotFound(DeviceID(serial: "ZZ"))) {
      try DeviceSelection.pickDevice(serial: "ZZ", from: [first])
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
