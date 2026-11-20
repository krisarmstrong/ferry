import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// Eject and Remove Ferry, and where unsent changes are shown.
extension AppModelTests {
  /// A folder like the one the system saves unsent changes to, holding a file or empty.
  static func savedFolder(holdingFile: Bool) throws -> URL {
    let folder = TestScratch.root.appending(
      path: "Ferry unsent \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if holdingFile {
      try Data("x".utf8).write(to: folder.appending(path: "report.txt"))
    }
    return folder
  }

  @Test func removeFerryCallsRemoveAllThenUnregister() async {
    let services = FakeServices(log: log)
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.removeFerry()
    #expect(
      log.all == [
        "removeAllDomains", "unregisterAgent", "readLoginItem", "opensAtLogin false", "quit",
      ])
  }

  @Test func removeFerryQuitsWhenOnlyTheLoginItemRemains() async {
    let services = FakeServices(log: log)
    services.failLoginItem = true
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.removeFerry()
    #expect(
      log.all == [
        "removeAllDomains", "unregisterAgent", "readLoginItem", "opensAtLogin false", "quit",
      ])
  }

  @Test func removeFerryStopsWhenDomainsRemain() async {
    let client = FakeClient(log: log)
    client.failRemoveAll()
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.removeFerry()
    #expect(log.all == ["removeAllDomains"])
    // Help shows it under Remove Ferry…; the menu's error row is for the menu's own actions.
    #expect(model.removalError != nil)
    #expect(model.actionError == nil)
  }

  /// Remove Ferry… shows only its own failure: not one from before it, nor a later one.
  @Test func removeFerryKeepsItsOwnError() async {
    let client = FakeClient(log: log)
    client.failRemoveAll()
    let services = FakeServices(log: log)
    services.failLoginItem = true
    let model = AppModel(client: client, services: services)
    model.requestOpensAtLogin(false)
    await model.loginItemSettled()
    #expect(model.actionError != nil)
    #expect(model.removalError == nil)
    await model.removeFerry()
    let removal = model.removalError
    #expect(removal != nil)
    model.requestOpensAtLogin(true)
    await model.loginItemSettled()
    #expect(model.removalError == removal)
  }

  /// Opening Help again starts Remove Ferry… afresh: an old failure is not shown under it.
  @Test func helpAppearingClearsAnOldRemovalError() async {
    let client = FakeClient(log: log)
    client.failRemoveAll()
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.removeFerry()
    #expect(model.removalError != nil)
    model.helpAppeared()
    #expect(model.removalError == nil)
  }

  @Test func ejectShowsWhereUnsentChangesWereSaved() async throws {
    let saved = try Self.savedFolder(holdingFile: true)
    defer { try? FileManager.default.removeItem(at: saved) }
    let client = FakeClient(log: log)
    client.preserve([saved])
    let model = AppModel(client: client, services: FakeServices(log: log))

    await model.eject(DeviceID(serial: "A1"))

    #expect(model.preservedChanges == [saved])
    #expect(model.actionError == nil)
    model.revealPreservedChanges()
    #expect(log.all.last == "reveal \(saved.path)")
  }

  /// The system can name a location it left empty, or none at all: nothing to show then.
  @Test func ejectShowsNoMessageForAnEmptyOrMissingLocation() async throws {
    let empty = try Self.savedFolder(holdingFile: false)
    defer { try? FileManager.default.removeItem(at: empty) }
    let missing = TestScratch.root.appending(path: "Ferry gone \(UUID())")
    let client = FakeClient(log: log)
    client.preserve([empty, missing])
    let model = AppModel(client: client, services: FakeServices(log: log))

    await model.eject(DeviceID(serial: "A1"))

    #expect(model.preservedChanges.isEmpty)
  }

  @Test func ejectWithNothingUnsentShowsNoMessage() async {
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    await model.eject(DeviceID(serial: "A1"))
    #expect(model.preservedChanges.isEmpty)
  }

  /// Ferry quits right after Remove Ferry, so a menu message would never be seen: the saved
  /// changes are shown in Finder instead, if there are any.
  @Test(arguments: [true, false])
  func removeFerryRevealsSavedChangesBeforeQuitting(holdingFile: Bool) async throws {
    let saved = try Self.savedFolder(holdingFile: holdingFile)
    defer { try? FileManager.default.removeItem(at: saved) }
    let client = FakeClient(log: log)
    client.preserve([saved])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.removeFerry()
    let reveal = holdingFile ? ["reveal \(saved.path)"] : []
    #expect(
      log.all
        == ["removeAllDomains", "unregisterAgent"] + reveal + [
          "readLoginItem", "opensAtLogin false", "quit",
        ])
  }
}
