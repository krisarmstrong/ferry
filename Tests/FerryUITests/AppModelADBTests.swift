import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

@MainActor
struct AppModelADBTests {
  let log = CallLog()

  private func model(_ client: FakeClient) -> AppModel {
    AppModel(client: client, services: FakeServices(log: log))
  }

  @Test func statusCarriesWhatAdbReportsAndWhoWaitsForAllow() async {
    let client = FakeClient(log: log)
    client.setStatus(
      [device("A1", model: "Pixel 8", .ready([]))], adb: .notInstalled,
      awaitingUSBDebugging: [DeviceID(serial: "A1")], awaitingAuthorization: ["192.0.2.31:5555"])
    let model = model(client)
    await model.refresh()
    #expect(model.adbStatus == .notInstalled)
    #expect(model.isAwaitingUSBDebugging(DeviceID(serial: "A1")))
    #expect(!model.isAwaitingUSBDebugging(DeviceID(serial: "B1")))
    #expect(model.awaitingAuthorization == ["192.0.2.31:5555"])
  }

  /// A Mac with no Android device has no use for adb, so the menu does not nag about it.
  @Test(arguments: [
    (ADBStatus?.some(.notInstalled), true, true), (.some(.notInstalled), false, false),
    (.some(.available), true, false), (.some(.serverDown), true, false), (nil, true, false),
  ])
  func installRowShowsOnlyWithADeviceAndNoAdb(
    status: ADBStatus?, withDevice: Bool, shows: Bool
  ) async {
    let client = FakeClient(log: log)
    client.setStatus(withDevice ? [device("A1", model: "Pixel 8", .ready([]))] : [], adb: status)
    let model = model(client)
    await model.refresh()
    #expect(model.showsInstallADB == shows)
  }

  /// adb is installed but its server does not answer: Check Again is how the user retries.
  @Test(arguments: [
    (ADBStatus?.some(.serverDown), true, true), (.some(.serverDown), false, false),
    (.some(.notInstalled), true, false), (.some(.available), true, false), (nil, true, false),
  ])
  func notRunningRowShowsOnlyWithADeviceAndAStoppedServer(
    status: ADBStatus?, withDevice: Bool, shows: Bool
  ) async {
    let client = FakeClient(log: log)
    client.setStatus(withDevice ? [device("A1", model: "Pixel 8", .ready([]))] : [], adb: status)
    let model = model(client)
    await model.refresh()
    #expect(model.showsADBNotRunning == shows)
  }

  /// Check Again is no reason to drop the notice of unsent changes.
  @Test func checkAgainKeepsTheUnsentChangesNotice() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ferry-kept-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appending(path: "file"))
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = FakeClient(log: log)
    client.setStatus([])
    let model = model(client)
    await model.refresh()
    model.preservedChanges = [folder]
    await model.recheckADB()
    #expect(model.preservedChanges == [folder])
  }

  @Test func checkAgainAsksTheAgentThenReadsStatus() async {
    let client = FakeClient(log: log)
    client.setStatus([device("A1", model: "Pixel 8", .ready([]))], adb: .notInstalled)
    let model = model(client)
    await model.refresh()
    client.setStatus([device("A1", model: "Pixel 8", .ready([]))], adb: .available)
    await model.recheckADB()
    #expect(log.all.suffix(2) == ["recheckADB", "status"])
    #expect(model.adbStatus == .available)
    #expect(!model.showsInstallADB)
  }

  @Test func copyPutsTheInstallCommandOnThePasteboard() {
    model(FakeClient(log: log)).copyInstallCommand()
    #expect(log.all == ["copy brew install --cask android-platform-tools"])
  }

  @Test func usbDebuggingGuideOpensOnTheDevicesFamily() {
    let model = model(FakeClient(log: log))
    model.showUSBDebuggingGuide(for: device("A1", model: "LinkRunner-100G", .ready([])))
    #expect(model.isGuidePresented)
    #expect(model.guideTopic == .usbDebugging)
    #expect(model.guideFamily == .netAllyAndroid8Board)
    #expect(model.takeGuideOpenRequest())
  }

  @Test func usbDebuggingGuideForAnUnknownModelShowsThePicker() {
    let model = model(FakeClient(log: log))
    model.showUSBDebuggingGuide(for: device("P1", model: "Pixel 8", .ready([])))
    #expect(model.guideTopic == .usbDebugging)
    #expect(model.guideFamily == nil)
  }

  @Test func theFileTransferGuideOpensOnTheFileTransferTopic() {
    let model = model(FakeClient(log: log))
    model.showUSBDebuggingGuide(for: nil)
    model.showGuide(for: device("A1", model: "LinkRunner-100G", .notSharingFiles))
    #expect(model.guideTopic == .fileTransfer)
    model.showUSBDebuggingGuide(for: nil)
    model.showGuide(family: .otherAndroid10Plus)
    #expect(model.guideTopic == .fileTransfer)
  }

  /// An unauthorised device adb lists alone is not a device to walk through file transfer.
  @Test func anADBDeviceNotSharingDoesNotOpenTheTransferGuide() async {
    let client = FakeClient(log: log)
    client.setStatus(
      [device("A1", model: "LinkRunner-100G", .notSharingFiles, method: .usbADB)],
      adb: .available, awaitingUSBDebugging: [DeviceID(serial: "A1")])
    let model = model(client)
    await model.refresh()
    #expect(!model.isGuidePresented)
  }

  /// A Wi-Fi-only user (a device remembered on the network, nothing on USB) gets the install
  /// hint, and no "No device connected" or file-transfer guide.
  @Test func aRememberedNetworkDeviceCountsAsADevice() async {
    let client = FakeClient(log: log)
    let address = WirelessEndpoint(parsing: "192.0.2.31")!
    client.setStatus(
      [], adb: .notInstalled,
      remembered: [
        RememberedDevice(id: DeviceID(serial: "W1"), name: "EtherScope nXG", addresses: [address])
      ])
    let model = model(client)
    await model.refresh()
    #expect(model.showsInstallADB)
    #expect(!model.showsNoDevice)
    model.considerEmptyGuide(openFor: .seconds(60))
    #expect(!model.isGuidePresented)
  }

  /// With nothing at all, opening a network form is what asks for adb.
  @Test func openingANetworkFormOffersAdb() async {
    let client = FakeClient(log: log)
    client.setStatus([], adb: .notInstalled)
    let model = model(client)
    await model.refresh()
    #expect(model.showsNoDevice)
    #expect(!model.showsInstallADB)
    model.openNetworkForm(.address)
    #expect(model.showsInstallADB)
  }
}
