import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// The menu names each hidden location whose changes wait to be sent, as the agent reports them.
@MainActor
struct AppModelWaitingTests {
  @Test func theModelKeepsTheLocationsWaitingToSend() async {
    let log = CallLog()
    let client = FakeClient(log: log)
    client.setStatus([], waitingToSend: ["Phone", "Phone – SD card"])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    #expect(model.waitingToSend == ["Phone", "Phone – SD card"])

    client.setStatus([])
    await model.refresh()
    #expect(model.waitingToSend.isEmpty)
  }

  /// A device names itself, so a bidi override in its name is spelled out, not obeyed.
  @Test func theLineEscapesTheDeviceName() {
    let line = WaitingChangesRow.line("Phone\u{202E}")
    #expect(line.text == "Phone\\u{202E}: changes wait to be sent. Reconnect it to finish.")
  }

  /// Originals of replaces cut short wait on the Mac for their device: the menu counts them.
  @Test func theModelCountsFilesWaitingToGoBack() async {
    let log = CallLog()
    let client = FakeClient(log: log)
    client.setStatus([], pendingBackups: 2)
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    #expect(model.pendingBackups == 2)
    #expect(WaitingChangesRow.backupsLine(2).text == "Files waiting to go back to their device: 2")
  }
}
