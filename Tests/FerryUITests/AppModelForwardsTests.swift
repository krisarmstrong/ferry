import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// Port Forwarding in a device's expansion: the disclosure loads the list when it opens, the
/// ports typed stay with the device, and the disclosure closes with its device's row.
@MainActor
struct AppModelForwardsTests {
  let log = CallLog()
  let id = DeviceID(serial: "0123456789abcdef")
  let other = DeviceID(serial: "fedcba9876543210")
  let client: FakeClient

  init() {
    client = FakeClient(log: log)
    client.setStatus([
      device(id.serial, model: "EtherScope-nXG", .ready([]), method: .usbADB),
      device(other.serial, model: "Pixel 9", .ready([]), method: .wifiADB),
    ])
  }

  private func model() async -> AppModel {
    let model = AppModel(client: client, services: FakeServices(log: log), sleep: { _ in })
    await model.refresh()
    model.toggleExpansion(.device(id))
    #expect(model.isExpanded(.device(id)))
    return model
  }

  @Test func openingTheDisclosureLoadsTheList() async throws {
    client.forwardList.withLock { $0 = [PortForward(local: 8080, remote: 80)] }
    let model = await model()
    #expect(model.openForwards(of: id) == nil)
    await model.toggleForwards(of: id)
    let session = try #require(model.openForwards(of: id))
    #expect(log.all.contains("forwards \(id.serial)"))
    #expect(session.forwards == [PortForward(local: 8080, remote: 80)])
    await model.toggleForwards(of: id)
    #expect(model.openForwards(of: id) == nil)
  }

  @Test func addingAndRemovingGoThroughTheAgent() async throws {
    let model = await model()
    await model.toggleForwards(of: id)
    let session = try #require(model.openForwards(of: id))
    session.localPort = "8080"
    session.remotePort = "80"
    await session.add()
    #expect(log.all.contains("addForward \(id.serial) 8080 80"))
    #expect(model.openForwards(of: id)?.forwards == [PortForward(local: 8080, remote: 80)])
    await session.remove(PortForward(local: 8080, remote: 80))
    #expect(log.all.contains("removeForward \(id.serial) 8080"))
    #expect(model.openForwards(of: id)?.forwards == [])
  }

  /// The menu redraws its rows on every status: what was typed is the model's, not the row's.
  @Test func typedPortsSurviveARefresh() async throws {
    let model = await model()
    await model.toggleForwards(of: id)
    try #require(model.openForwards(of: id)).localPort = "8080"
    await model.refresh()
    #expect(model.openForwards(of: id)?.localPort == "8080")
  }

  /// Opening another row, or the menu opening again, closes the disclosure; the ports typed
  /// are still there when it opens again, and the list is read again.
  @Test func theDisclosureClosesWithItsRowAndKeepsWhatWasTyped() async throws {
    let model = await model()
    await model.toggleForwards(of: id)
    try #require(model.openForwards(of: id)).localPort = "8080"
    model.toggleExpansion(.device(other))
    #expect(model.openForwards(of: id) == nil)
    model.toggleExpansion(.device(id))
    #expect(model.openForwards(of: id) == nil)
    await model.toggleForwards(of: id)
    model.resetExpansion()
    #expect(model.openForwards(of: id) == nil)
    await model.refresh()
    model.toggleExpansion(.device(id))
    await model.toggleForwards(of: id)
    #expect(model.openForwards(of: id)?.localPort == "8080")
    #expect(log.all.filter { $0 == "forwards \(id.serial)" }.count == 3)
  }

  /// One disclosure at a time, and only on the expanded device.
  @Test func onlyTheExpandedDeviceShowsItsForwards() async {
    let model = await model()
    await model.toggleForwards(of: other)
    #expect(model.openForwards(of: other) == nil)
  }

  @Test func aDeviceThatGoesTakesItsForwardsWithIt() async throws {
    let model = await model()
    await model.toggleForwards(of: id)
    try #require(model.openForwards(of: id)).localPort = "8080"
    client.setStatus([device(other.serial, model: "Pixel 9", .ready([]), method: .wifiADB)])
    await model.refresh()
    client.setStatus([device(id.serial, model: "EtherScope-nXG", .ready([]), method: .usbADB)])
    await model.refresh()
    model.toggleExpansion(.device(id))
    await model.toggleForwards(of: id)
    #expect(model.openForwards(of: id)?.localPort == "")
  }
}
