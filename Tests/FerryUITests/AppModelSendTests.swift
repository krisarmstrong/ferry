import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// Send File…: the chosen files go into the device's Download folder, as Finder's Send to sends
/// them, and the menu says how it went.
@MainActor
struct AppModelSendTests {
  let log = CallLog()
  let id = DeviceID(serial: "0123456789abcdef")

  private func file(_ name: String) throws -> URL {
    let url = try TestScratch.folder("send").appending(path: name)
    try Data("report".utf8).write(to: url)
    return url
  }

  private func model(_ client: FakeClient, picking urls: [URL]) async -> AppModel {
    client.setStatus([device(id.serial, model: "Pixel 8", .ready([]), method: .usbFileTransfer)])
    let services = FakeServices(log: log)
    services.pickedFiles = urls
    let model = AppModel(client: client, services: services)
    await model.refresh()
    return model
  }

  @Test func theChosenFilesAreSentAndTheMenuSaysWhere() async throws {
    let client = FakeClient(log: log)
    let model = await model(client, picking: [try file("Report.pdf")])
    await model.chooseAndSendFiles(on: id)
    #expect(
      log.all == [
        "status", "chooseFilesToSend", "sendFile \(id.serial) Report.pdf file:true", "status",
      ])
    #expect(model.toolMessage == "Sent “Report.pdf” to Pixel 8\nIt’s in Download.")
    #expect(model.actionError == nil)
  }

  @Test func cancellingSendsNothing() async {
    let client = FakeClient(log: log)
    let model = await model(client, picking: [])
    await model.chooseAndSendFiles(on: id)
    #expect(log.all == ["status", "chooseFilesToSend"])
    #expect(model.toolMessage == nil)
  }

  @Test func aFileThatWasNotSentIsAnError() async throws {
    let client = FakeClient(log: log)
    client.setSend(.failure(.insufficientSpace(needed: 2_000, free: 1_000)))
    let model = await model(client, picking: [try file("Report.pdf")])
    await model.chooseAndSendFiles(on: id)
    #expect(
      model.actionError
        == "Couldn’t send “Report.pdf” to Pixel 8\nThe device doesn’t have enough free space.")
    #expect(model.toolMessage == nil)
  }
}
