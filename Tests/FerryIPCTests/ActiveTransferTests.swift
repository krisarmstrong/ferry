import DeviceKit
import Testing

@testable import FerryIPC

/// Sizes come from the device, so the percentage must hold for any of them.
struct ActiveTransferTests {
  @Test(arguments: [
    (UInt64(0), UInt64(0), 0), (0, 100, 0), (25, 100, 25), (100, 100, 100), (150, 100, 100),
    (UInt64.max, UInt64.max, 100), (UInt64.max / 2, UInt64.max, 49), (UInt64.max, 1, 100),
    (1, UInt64.max, 0),
  ])
  func percentNeverOverflows(completed: UInt64, total: UInt64, percent: Int) {
    let transfer = ActiveTransfer(
      device: DeviceID(serial: "A"), name: "x", direction: .toMac, completed: completed,
      total: total)
    #expect(transfer.percent == percent)
  }
}
