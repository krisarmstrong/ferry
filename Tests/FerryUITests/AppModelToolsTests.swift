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

  private func names(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
  }

  /// The app creates the file where screenshots go, the agent fills it, the app names it and
  /// shows it.
  @Test func aScreenshotIsSavedByTheAppAndShownInFinder() async throws {
    let client = FakeClient(log: log)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    client.setTool(.done, writes: png)
    client.setStatus([device(id.serial, model: "LinkRunner-100G", .ready([]), method: .usbADB)])
    let services = FakeServices(log: log)
    let folder = try TestScratch.folder("shots")
    services.folders = [folder]
    let model = model(client, services: services)
    await model.refresh()
    await model.takeScreenshot(on: id)
    let shots = folder.appending(path: "LinkRunner-100G/Screenshots", directoryHint: .isDirectory)
    let saved = try names(shots)
    #expect(saved.count == 1)
    let name = try #require(saved.first)
    #expect(name.hasPrefix("Screenshot LinkRunner-100G ") && name.hasSuffix(".png"))
    #expect(try Data(contentsOf: shots.appending(path: name)) == png)
    #expect(log.all.contains("screenshot \(id.serial) file:true"))
    #expect(log.all.contains("reveal \(shots.appending(path: name).path)"))
    #expect(model.actionError == nil)
  }

  @Test func aFailedCaptureLeavesNothing() async throws {
    let client = FakeClient(log: log)
    client.setTool(.toolFailed(.noImage), writes: Data("half".utf8))
    let services = FakeServices(log: log)
    let folder = try TestScratch.folder("shots")
    services.folders = [folder]
    let model = model(client, services: services)
    await model.takeScreenshot(on: id)
    #expect(
      model.actionError?.text == "The device didn't send a screenshot. Unlock it and try again.")
    #expect(try names(folder.appending(path: "Android/Screenshots")).isEmpty)
    #expect(!log.all.contains { $0.hasPrefix("reveal") })
  }

  /// The device's folders are made by the first save, not before: Documents is asked for only
  /// then.
  @Test func theDevicesFolderIsMadeByTheFirstSave() async throws {
    let client = FakeClient(log: log)
    client.setStatus([device(id.serial, model: "LinkRunner-100G", .ready([]), method: .usbADB)])
    let services = FakeServices(log: log)
    let root = try TestScratch.folder("documents").appending(
      path: "Ferry", directoryHint: .isDirectory)
    services.folders = [root]
    let model = model(client, services: services)
    await model.refresh()
    #expect(!FileManager.default.fileExists(atPath: root.path))
    await model.takeScreenshot(on: id)
    #expect(try names(root.appending(path: "LinkRunner-100G/Screenshots")).count == 1)
  }

  /// Two units of one model each get their own folder, named as the menu names them.
  @Test func twoUnitsOfOneModelHaveTheirOwnFolders() async throws {
    let client = FakeClient(log: log)
    let other = DeviceID(serial: "fedcba9876543210")
    client.setStatus([
      device(id.serial, model: "LinkRunner-100G", .ready([]), method: .usbADB),
      device(other.serial, model: "LinkRunner-100G", .ready([]), method: .usbADB),
    ])
    let services = FakeServices(log: log)
    let root = try TestScratch.folder("two-units")
    services.folders = [root]
    let model = model(client, services: services)
    await model.refresh()
    await model.takeScreenshot(on: id)
    await model.takeScreenshot(on: other)
    #expect(try names(root) == ["LinkRunner-100G (3210)", "LinkRunner-100G (cdef)"])
  }

  /// A folder that cannot be made is passed over for the next.
  @Test func anUnusableFolderFallsBackToTheNext() async throws {
    let client = FakeClient(log: log)
    let services = FakeServices(log: log)
    let scratch = try TestScratch.folder("fallback")
    let blocker = scratch.appending(path: "a-file")
    try Data().write(to: blocker)
    let usable = scratch.appending(path: "usable", directoryHint: .isDirectory)
    services.folders = [blocker.appending(path: "Ferry", directoryHint: .isDirectory), usable]
    await model(client, services: services).takeScreenshot(on: id)
    #expect(try names(usable.appending(path: "Android/Screenshots")).count == 1)
  }

  @Test func withNowhereToSaveNothingIsSent() async throws {
    let services = FakeServices(log: log)
    let model = model(FakeClient(log: log), services: services)
    await model.takeScreenshot(on: id)
    #expect(model.actionError == DevicePresentation.notice(for: .cannotSave))
    #expect(!log.all.contains { $0.hasPrefix("screenshot") })
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

  /// Cancel stops the copy; the user asked, so nothing is shown as an error.
  @Test func cancelStopsAnInstallQuietly() async throws {
    let client = FakeClient(log: log)
    client.parkInstalls()
    let model = model(client)
    let install = Task { await model.installAPK(try apk(), on: id) }
    while !log.all.contains("installAPK \(id.serial) Ferry Test.apk parked") {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.installs[id] != nil)

    model.cancelInstall(on: id)
    try await install.value

    #expect(log.all.contains("installAPK cancelled"))
    #expect(model.installs.isEmpty)
    #expect(model.actionError == nil)
    #expect(model.toolMessage == nil)
  }

  /// Cancel is offered while the app is copied, not once the device is installing it.
  @Test func cancelIsOfferedOnlyDuringTheCopy() {
    #expect(DevicePresentation.offersCancel(AppInstall(name: "a.apk", percent: 99)))
    #expect(!DevicePresentation.offersCancel(AppInstall(name: "a.apk", percent: 100)))
  }

  @Test func pmsRefusalIsShownInPlainWords() async throws {
    let client = FakeClient(log: log)
    client.setTool(.toolFailed(.installFailed("INSTALL_FAILED_VERSION_DOWNGRADE")))
    let model = model(client)
    await model.installAPK(try apk(), on: id)
    #expect(
      model.actionError?.text == "A newer version of the app is installed. Uninstall it first.")
    #expect(model.toolMessage == nil)
  }

  /// Start answers once the recording has ended; the app then collects the video into its own
  /// file and shows it.
  @Test func aRecordingIsCollectedWhenItEnds() async throws {
    let client = FakeClient(log: log)
    let started = Date(timeIntervalSince1970: 1_795_039_767)
    client.setStatus(
      [device(id.serial, model: "LinkRunner-100G", .ready([]), method: .usbADB)],
      recordings: [ActiveRecording(device: id, started: started, stopping: true, finished: true)])
    let mp4 = Data("....ftypmp42".utf8)
    client.setTool(.done, writes: mp4)
    let services = FakeServices(log: log)
    let folder = try TestScratch.folder("recordings")
    services.folders = [folder]
    let model = model(client, services: services)
    await model.startRecording(on: id)
    #expect(log.all.contains("startRecording \(id.serial)"))
    #expect(log.all.contains("saveRecording \(id.serial) file:true"))
    let recordings = folder.appending(path: "LinkRunner-100G/Screen Recordings")
    let name = try #require(try names(recordings).first)
    #expect(name.hasPrefix("Screen Recording LinkRunner-100G ") && name.hasSuffix(".mp4"))
    #expect(try Data(contentsOf: recordings.appending(path: name)) == mp4)
    #expect(log.all.contains("reveal \(recordings.appending(path: name).path)"))
    #expect(log.all.filter { $0.hasPrefix("saveRecording") }.count == 1)
  }

  /// A recording that finished while no request waited (the app was relaunched) is collected
  /// once the status lists it.
  @Test func aRecordingFinishedBeforeARelaunchIsStillCollected() async throws {
    let client = FakeClient(log: log)
    client.setStatus(
      [device(id.serial, model: "LinkRunner-100G", .ready([]), method: .usbADB)],
      recordings: [ActiveRecording(device: id, started: .now, stopping: false, finished: true)])
    client.setTool(.done, writes: Data("....ftypmp42".utf8))
    let services = FakeServices(log: log)
    let folder = try TestScratch.folder("recordings")
    services.folders = [folder]
    let model = model(client, services: services)
    await model.refresh()
    for collection in model.backgroundCollections.values { await collection.value }
    #expect(try names(folder).count == 1)
    #expect(log.all.contains("saveRecording \(id.serial) file:true"))
  }

  @Test func stopIsSent() async {
    let model = model(FakeClient(log: log))
    await model.stopRecording(on: id)
    #expect(log.all.first == "stopRecording \(id.serial)")
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

/// Where captures go and what they are called, as macOS names its own.
struct CaptureFilesTests {
  /// 2026-11-18 22:09:27 UTC.
  private let moment = Date(timeIntervalSince1970: 1_795_039_767)

  @Test func namesFollowMacOS() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    #expect(
      CaptureFiles.baseName(.screenshot, model: "LinkRunner-100G", at: moment, timeZone: utc)
        == "Screenshot LinkRunner-100G 2026-11-18 at 22.09.27")
    #expect(
      CaptureFiles.baseName(.recording, model: "EtherScope nXG", at: moment, timeZone: utc)
        == "Screen Recording EtherScope nXG 2026-11-18 at 22.09.27")
  }

  @Test(arguments: [
    ("LinkRunner-100G", "LinkRunner-100G"), ("a/b:c", "a-b-c"), ("..hidden", "hidden"),
    ("evil\u{202E}gnp.exe", "evilgnp.exe"), ("line\nbreak\u{0}", "linebreak"), ("", "Android"),
    ("  ", "Android"), (String(repeating: "x", count: 100), String(repeating: "x", count: 64)),
  ])
  func modelsBecomeOneSafeComponent(model: String, safe: String) {
    #expect(CaptureFiles.fileSafe(model) == safe)
  }

  /// `~/Documents/Ferry/<device>/Screenshots` and `…/Screen Recordings`.
  @Test func capturesGoInDocumentsByDevice() {
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    let root = CaptureFiles.documentsRoot(home: home)
    #expect(root.path == "/Users/someone/Documents/Ferry")
    #expect(
      CaptureFiles.folder(CaptureFiles.screenshotsFolder, device: "LinkRunner-100G", in: root).path
        == "/Users/someone/Documents/Ferry/LinkRunner-100G/Screenshots")
    #expect(
      CaptureFiles.folder(CaptureFiles.recordingsFolder, device: "EtherScope nXG", in: root).path
        == "/Users/someone/Documents/Ferry/EtherScope nXG/Screen Recordings")
    #expect(
      CaptureFiles.folder(CaptureFiles.screenshotsFolder, device: "a/b:c", in: root).path
        == "/Users/someone/Documents/Ferry/a-b-c/Screenshots")
  }

  @Test func anExistingFileIsNeverReplaced() throws {
    let folder = try TestScratch.folder("never-replace")
    try Data("mine".utf8).write(to: folder.appending(path: "Shot.png"))
    try Data("mine too".utf8).write(to: folder.appending(path: "Shot 2.png"))
    let (temporary, handle) = try #require(CaptureFiles.temporary(in: folder))
    try handle.write(contentsOf: Data("new".utf8))
    try handle.close()
    let placed = try CaptureFiles.place(temporary, base: "Shot", fileExtension: "png")
    #expect(placed.lastPathComponent == "Shot 3.png")
    #expect(try Data(contentsOf: folder.appending(path: "Shot.png")) == Data("mine".utf8))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        == ["Shot 2.png", "Shot 3.png", "Shot.png"])
  }
}
