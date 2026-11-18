import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

private let device = DeviceID(serial: "0123456789abcdef")
private let target = ADBTools.Target(serial: "0123456789abcdef", model: "LinkRunner-100G")
/// 2026-11-18 22:09:27 UTC.
private let moment = Date(timeIntervalSince1970: 1_795_039_767)

/// The agent's side of the tools: who may use them, what is saved where and under which name,
/// and that nothing is left behind.
@Suite(.timeLimit(.minutes(1)))
struct ADBToolsTests {
  let folder: URL
  let desktop: URL
  let scratch: URL

  init() throws {
    folder = try TestScratch.folder("captures")
    desktop = try TestScratch.folder("desktop")
    scratch = try TestScratch.folder("tools-scratch")
  }

  private func makeTools(
    _ fake: FakeToolDevice, served: Bool = true, folder: URL? = nil,
    limits: ADBTools.Limits = .init()
  ) -> ADBTools {
    let shots = folder ?? self.folder
    return ADBTools(
      device: fake, target: { _ in served ? target : nil }, folder: { shots }, desktop: desktop,
      scratch: scratch, now: { moment }, limits: limits)
  }

  private func names(_ url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
  }

  private func source(_ data: Data) throws -> FileHandle {
    let url = scratch.appending(path: "picked-\(UUID().uuidString).apk")
    try data.write(to: url)
    return try FileHandle(forReadingFrom: url)
  }

  /// The scratch folder holds only the files the test put there: the agent's copy is gone.
  private func agentCopies() throws -> [String] {
    try names(scratch).filter { !$0.hasPrefix("picked-") }
  }

  // MARK: Names and folders

  @Test func namesFollowMacOS() {
    let utc = TimeZone(identifier: "UTC")!
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

  @Test func theFolderIsWhereMacOSSavesScreenshots() {
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    let desktop = home.appending(path: "Desktop", directoryHint: .isDirectory)
    #expect(
      CaptureFiles.folder(location: "~/Pictures/Shots", home: home) { _ in true }.path
        == "/Users/someone/Pictures/Shots")
    #expect(
      CaptureFiles.folder(location: "/Volumes/Shots", home: home) { _ in true }.path
        == "/Volumes/Shots")
    #expect(CaptureFiles.folder(location: nil, home: home) { _ in true } == desktop)
    #expect(CaptureFiles.folder(location: "Shots", home: home) { _ in true } == desktop)
    #expect(CaptureFiles.folder(location: "/Volumes/Gone", home: home) { _ in false } == desktop)
  }

  @Test func anExistingFileIsNeverReplaced() throws {
    try Data("mine".utf8).write(to: folder.appending(path: "Shot.png"))
    try Data("mine too".utf8).write(to: folder.appending(path: "Shot 2.png"))
    let (temporary, handle) = try #require(CaptureFiles.temporary(in: folder))
    try handle.write(contentsOf: Data("new".utf8))
    try handle.close()
    let placed = try CaptureFiles.place(temporary, base: "Shot", fileExtension: "png")
    #expect(placed.lastPathComponent == "Shot 3.png")
    #expect(try Data(contentsOf: folder.appending(path: "Shot.png")) == Data("mine".utf8))
    #expect(try names(folder) == ["Shot 2.png", "Shot 3.png", "Shot.png"])
  }

  @Test(arguments: [
    (ConnectionMethod.usbADB, true), (.wifiADB, true), (.usbFileTransfer, false),
  ])
  func onlyADeviceServedOverADBHasTools(method: ConnectionMethod, has: Bool) {
    let info = DeviceInfo(id: device, manufacturer: "", model: "LinkRunner-100G")
    let storage = StorageInfo(
      id: StorageID(device: device, key: "internal"), description: "Internal", capacity: 1, free: 1)
    let routes = ADBRoutes(usb: "0123456789abcdef", wireless: ["10.0.0.5:5555"])
    let ready = AttachedDevice(info: info, state: .ready([storage]), method: method)
    #expect((ADBTools.target(for: device, devices: [ready], routes: routes) != nil) == has)
    let ejected = AttachedDevice(info: info, state: .ejected, method: method)
    #expect(ADBTools.target(for: device, devices: [ejected], routes: routes) == nil)
    #expect(ADBTools.target(for: device, devices: [ready], routes: nil) == nil)
  }

  /// USB while the cable is in, as the session.
  @Test func toolsUseTheSessionsRoute() {
    let info = DeviceInfo(id: device, manufacturer: "", model: "LinkRunner-100G")
    let ready = AttachedDevice(info: info, state: .ready([]), method: .usbADB)
    let routes = ADBRoutes(usb: "usb-serial", wireless: ["10.0.0.5:5555"])
    #expect(ADBTools.target(for: device, devices: [ready], routes: routes)?.serial == "usb-serial")
  }

  // MARK: Screenshot

  @Test func aScreenshotIsSavedWhereMacOSSavesThem() async throws {
    let fake = FakeToolDevice()
    let outcome = try await makeTools(fake).screenshot(device)
    let base = CaptureFiles.baseName(.screenshot, model: "LinkRunner-100G", at: moment)
    #expect(outcome == .saved(folder.appending(path: base + ".png")))
    #expect(try names(folder) == [base + ".png"])
    #expect(try Data(contentsOf: folder.appending(path: base + ".png")) == FakeToolDevice.png)
    #expect(await fake.screenshots == [target.serial])
  }

  @Test func aSecondScreenshotInTheSameSecondGetsTheNextName() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake)
    _ = try await tools.screenshot(device)
    let base = CaptureFiles.baseName(.screenshot, model: "LinkRunner-100G", at: moment)
    #expect(try await tools.screenshot(device) == .saved(folder.appending(path: base + " 2.png")))
  }

  @Test func somethingOtherThanAnImageIsNotSaved() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.image = Data("/system/bin/sh: screencap: not found\n".utf8) }
    #expect(try await makeTools(fake).screenshot(device) == .failed(.noImage))
    #expect(try names(folder).isEmpty)
  }

  @Test func anUnwritableFolderFallsBackToTheDesktop() async throws {
    let fake = FakeToolDevice()
    let gone = folder.appending(path: "gone", directoryHint: .isDirectory)
    guard case .saved(let url) = try await makeTools(fake, folder: gone).screenshot(device) else {
      Issue.record("not saved")
      return
    }
    #expect(url.deletingLastPathComponent().standardizedFileURL == desktop.standardizedFileURL)
  }

  @Test func withNowhereToWriteNothingIsSaved() async throws {
    let fake = FakeToolDevice()
    try FileManager.default.removeItem(at: desktop)
    let gone = folder.appending(path: "gone", directoryHint: .isDirectory)
    #expect(try await makeTools(fake, folder: gone).screenshot(device) == .failed(.cannotSave))
  }

  @Test func aDeviceNotOnADBGetsNoTools() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake, served: false)
    #expect(try await tools.screenshot(device) == .failed(.notOverADB))
    #expect(try await tools.startRecording(device) == .failed(.notOverADB))
    let apk = try source(ZipFixture.archive(["AndroidManifest.xml"]))
    #expect(
      try await tools.installAPK(apk.fileDescriptor, on: device) { _, _ in true }
        == .failed(.notOverADB))
    #expect(await fake.screenshots.isEmpty)
    #expect(await fake.recordingsStarted.isEmpty)
    #expect(await fake.installs.isEmpty)
    #expect(await tools.recordingsRunning().isEmpty)
  }

  @Test func aLostDeviceIsDisconnected() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.failure = .deviceGone("0123456789abcdef") }
    await #expect(throws: TransportError.deviceDisconnected) {
      try await makeTools(fake).screenshot(device)
    }
    #expect(try names(folder).isEmpty)
  }

  // MARK: APK

  @Test func anAPKIsCheckedThenInstalled() async throws {
    let fake = FakeToolDevice()
    let apk = ZipFixture.archive(["classes.dex", "AndroidManifest.xml", "res/layout/a.xml"])
    let handle = try source(apk)
    // A client's offset is not trusted.
    try handle.seekToEnd()
    #expect(
      try await makeTools(fake).installAPK(handle.fileDescriptor, on: device) { _, _ in true }
        == .done)
    let installs = await fake.installs
    #expect(installs.map(\.serial) == [target.serial])
    #expect(installs.map(\.contents) == [apk])
    #expect(try agentCopies().isEmpty)
  }

  @Test(arguments: [
    Data("not a zip at all".utf8),
    // A ZIP, but not an app.
    ZipFixture.archive(["readme.txt", "res/AndroidManifest.xml"]),
    // The manifest name only in the file data, not the directory.
    Data([0x50, 0x4B, 0x03, 0x04]) + Data("AndroidManifest.xml".utf8),
    Data(),
  ])
  func somethingOtherThanAnAppIsRefused(contents: Data) async throws {
    let fake = FakeToolDevice()
    let handle = try source(contents)
    #expect(
      try await makeTools(fake).installAPK(handle.fileDescriptor, on: device) { _, _ in true }
        == .failed(.notAnAPK))
    #expect(await fake.installs.isEmpty)
    #expect(try agentCopies().isEmpty)
  }

  @Test func anAPKOverTheCapIsRefused() async throws {
    let fake = FakeToolDevice()
    var limits = ADBTools.Limits()
    limits.apkSize = 10
    let tools = makeTools(fake, limits: limits)
    let handle = try source(ZipFixture.archive(["AndroidManifest.xml"]))
    let outcome = try await tools.installAPK(handle.fileDescriptor, on: device) { _, _ in true }
    #expect(outcome == .failed(.apkTooLarge))
    #expect(await fake.installs.isEmpty)
    #expect(try agentCopies().isEmpty)
  }

  @Test func pmsRefusalIsPassedOn() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.installResult = .failed("INSTALL_FAILED_VERSION_DOWNGRADE") }
    let handle = try source(ZipFixture.archive(["AndroidManifest.xml"]))
    #expect(
      try await makeTools(fake).installAPK(handle.fileDescriptor, on: device) { _, _ in true }
        == .failed(.installFailed("INSTALL_FAILED_VERSION_DOWNGRADE")))
    #expect(try agentCopies().isEmpty)
  }

  @Test func aDeviceLostDuringInstallLeavesNoCopy() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.failure = .connectionClosed }
    let handle = try source(ZipFixture.archive(["AndroidManifest.xml"]))
    await #expect(throws: TransportError.deviceDisconnected) {
      try await makeTools(fake).installAPK(handle.fileDescriptor, on: device) { _, _ in true }
    }
    #expect(try agentCopies().isEmpty)
  }
}
