import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// The menu's tools: what is sent, what the user sees, and that a saved file is shown in Finder.
@MainActor
struct AppModelToolsTests {
  let log = CallLog()
  let id = DeviceID(serial: "0123456789abcdef")

  private func model(_ client: FakeClient, services: FakeServices? = nil) -> AppModel {
    AppModel(client: client, services: services ?? FakeServices(log: log))
  }

  private func apk(_ name: String = "Ferry Test.apk") throws -> URL {
    let url = try TestScratch.folder("apks").appending(path: name)
    try Data("PK".utf8).write(to: url)
    return url
  }

  @Test func aScreenshotIsShownInFinder() async {
    let client = FakeClient(log: log)
    let saved = URL(
      filePath: "/Users/someone/Downloads/Screenshot LinkRunner 2026-11-18 at 17.09.27.png")
    client.setTool(.saved(saved))
    let model = model(client)
    await model.takeScreenshot(on: id)
    #expect(log.all == ["screenshot \(id.serial)", "reveal \(saved.path)", "status"])
    #expect(model.actionError == nil)
  }

  @Test func aToolFailureIsShown() async {
    let client = FakeClient(log: log)
    client.setTool(.toolFailed(.noImage))
    let model = model(client)
    await model.takeScreenshot(on: id)
    #expect(model.actionError == "The device didn't send a screenshot. Unlock it and try again.")
    #expect(!log.all.contains { $0.hasPrefix("reveal") })
  }

  @Test func anAPKIsSentAsAnOpenFileWithItsName() async throws {
    let client = FakeClient(log: log)
    let model = model(client)
    await model.installAPK(try apk(), on: id)
    #expect(log.all == ["installAPK \(id.serial) Ferry Test.apk file:true", "status"])
    #expect(model.toolMessage == "Installed “Ferry Test.apk”.")
    #expect(model.installs.isEmpty)
  }

  /// A file dropped on the row that is not an `.apk` is not sent.
  @Test func aDroppedFileThatIsNotAnAPKIsNotSent() async throws {
    let model = model(FakeClient(log: log))
    await model.installAPK(try apk("notes.txt"), on: id)
    #expect(log.all.isEmpty)
  }

  @Test func installAppAsksForAFile() async throws {
    let services = FakeServices(log: log)
    let model = model(FakeClient(log: log), services: services)
    await model.chooseAndInstallAPK(on: id)
    #expect(log.all == ["chooseAPK"])
    services.pickedAPK = try apk()
    await model.chooseAndInstallAPK(on: id)
    #expect(log.all.dropFirst().first == "chooseAPK")
    #expect(log.all.contains("installAPK \(id.serial) Ferry Test.apk file:true"))
  }

  @Test func pmsRefusalIsShownInPlainWords() async throws {
    let client = FakeClient(log: log)
    client.setTool(.toolFailed(.installFailed("INSTALL_FAILED_VERSION_DOWNGRADE")))
    let model = model(client)
    await model.installAPK(try apk(), on: id)
    #expect(model.actionError == "A newer version of the app is installed. Uninstall it first.")
    #expect(model.toolMessage == nil)
  }

  @Test func aRecordingIsShownWhileRunningAndItsFileAfter() async {
    let client = FakeClient(log: log)
    let started = Date(timeIntervalSince1970: 1_763_503_767)
    client.setStatus(
      [], recordings: [ActiveRecording(device: id, started: started, stopping: false)])
    let model = model(client)
    await model.refresh()
    #expect(
      model.recording(on: id) == ActiveRecording(device: id, started: started, stopping: false))
    let saved = URL(filePath: "/Users/someone/Downloads/Screen Recording LinkRunner.mp4")
    client.setTool(.saved(saved))
    client.setStatus([])
    // Already recording: nothing is sent.
    await model.refresh()
    await model.startRecording(on: id)
    #expect(log.all.contains("startRecording \(id.serial)"))
    #expect(log.all.contains("reveal \(saved.path)"))
    #expect(model.recording(on: id) == nil)
    await model.stopRecording(on: id)
    #expect(log.all.contains("stopRecording \(id.serial)"))
  }

  @Test func aRunningRecordingIsNotStartedAgain() async {
    let client = FakeClient(log: log)
    client.setStatus(
      [], recordings: [ActiveRecording(device: id, started: .now, stopping: false)])
    let model = model(client)
    await model.refresh()
    await model.startRecording(on: id)
    #expect(!log.all.contains("startRecording \(id.serial)"))
  }
}
