import DeviceKit
import Foundation
import Testing

struct AttachedDeviceTests {
  static let storage = StorageInfo(
    id: StorageID(device: DeviceID(serial: "S1"), key: "Internal|vol0"),
    description: "Internal", capacity: 1_000, free: 900)
  static let errors: [TransportError] = [.notFound(.root), .io("broken pipe")]
  static let space = TransportError.insufficientSpace(needed: 10, free: 2)
  static let states: [DeviceState] =
    [.ready([storage]), .notSharingFiles, .busy] + (errors + [space]).map(DeviceState.failed)

  @Test(arguments: states)
  func stateRoundTripsThroughJSON(_ state: DeviceState) throws {
    let device = AttachedDevice(
      info: DeviceInfo(id: DeviceID(serial: "S1"), manufacturer: "NetAlly", model: "LR-G2"),
      state: state)
    let decoded = try JSONDecoder().decode(
      AttachedDevice.self, from: JSONEncoder().encode(device))
    #expect(decoded == device)
    #expect(decoded.id == device.info.id)
  }
}
