import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

@MainActor
struct AppModelTransferTests {
  @Test func transfersAreListedUnderTheirDevice() async {
    let log = CallLog()
    let client = FakeClient(log: log)
    let unit = DeviceID(serial: "U1")
    let copy = ActiveTransfer(
      device: unit, name: "trace.pcap", direction: .toMac, completed: 25, total: 100)
    client.setStatus([], transfers: [copy])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()

    #expect(model.transfers(on: unit) == [copy])
    #expect(model.transfers(on: DeviceID(serial: "other")).isEmpty)
    #expect(DevicePresentation.transferLine(copy) == "Copying “trace.pcap” to this Mac · 25%")
  }
}

/// A helper macOS will not run is a step for the user in System Settings, not a reason to quit
/// and reopen Ferry.
@MainActor
struct AppModelHelperTests {
  @Test(arguments: [HelperStatus.requiresApproval, .notFound])
  func aBlockedHelperIsShownWithItsSettings(status: HelperStatus) async {
    let log = CallLog()
    let services = FakeServices(log: log)
    services.helper = status
    let model = AppModel(client: UnreachableClient(), services: services)

    await model.refresh()

    #expect(model.agent == .unreachable)
    #expect(model.helper == status)
    model.openLoginItems()
    #expect(
      log.all.last == "open x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
  }

  @Test func anAllowedHelperThatDoesNotAnswerIsNotBlocked() async {
    let log = CallLog()
    let model = AppModel(client: UnreachableClient(), services: FakeServices(log: log))
    await model.refresh()
    #expect(model.helper == .allowed)
  }
}

/// The Open at login switch shows what the user chose while macOS applies it, and changes are
/// applied one after another in the order made.
@MainActor
struct AppModelLoginItemTests {
  @Test func theSwitchHoldsThePendingValueAndChangesApplyInOrder() async {
    let log = CallLog()
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    await model.launch()
    #expect(model.opensAtLogin)

    model.requestOpensAtLogin(false)
    #expect(!model.opensAtLogin)
    model.requestOpensAtLogin(true)
    #expect(model.opensAtLogin)
    await model.loginItemSettled()

    #expect(
      log.all.filter { $0.hasPrefix("opensAtLogin") } == [
        "opensAtLogin false", "opensAtLogin true",
      ])
    #expect(model.opensAtLogin)
  }

  @Test func aFailedChangeShowsWhatMacOSKept() async {
    let log = CallLog()
    let services = FakeServices(log: log)
    services.failLoginItem = true
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.launch()

    model.requestOpensAtLogin(false)
    await model.loginItemSettled()

    #expect(model.opensAtLogin)
    #expect(model.actionError != nil)
  }
}

/// The agent says it cannot watch USB: the menu says devices are looked for every 30 s.
@MainActor
struct AppModelUSBWatchTests {
  @Test func aFailedUSBWatchIsShownUntilItWorks() async {
    let log = CallLog()
    let client = FakeClient(log: log)
    let model = AppModel(client: client, services: FakeServices(log: log))
    client.setStatus([], usbWatchFailed: true)
    await model.refresh()
    #expect(model.usbWatchFailed)
    client.setStatus([])
    await model.refresh()
    #expect(!model.usbWatchFailed)
  }
}
