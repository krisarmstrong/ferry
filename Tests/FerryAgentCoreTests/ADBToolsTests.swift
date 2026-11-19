import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

private let device = DeviceID(serial: "0123456789abcdef")
private let serial = "0123456789abcdef"

/// The agent's side of the tools: who may use them, what reaches the client's file, and that the
/// files put on the device are journalled and removed.
@Suite(.timeLimit(.minutes(1)))
struct ADBToolsTests {
  let scratch: URL
  let journal: ToolJournal

  init() throws {
    scratch = try TestScratch.folder("tools-scratch")
    journal = ToolJournal(store: scratch.appending(path: "journal.json"))
  }

  private func makeTools(
    _ fake: FakeToolDevice, served: Bool = true, limits: ADBTools.Limits = .init()
  ) -> ADBTools {
    ADBTools(
      device: fake, target: { _ in served ? serial : nil }, journal: journal, scratch: scratch,
      limits: limits)
  }

  private func source(_ data: Data) throws -> FileHandle {
    let url = scratch.appending(path: "picked-\(UUID().uuidString).apk")
    try data.write(to: url)
    return try FileHandle(forReadingFrom: url)
  }

  /// A file the client created for the capture, open for writing.
  private func destination() throws -> (URL, FileHandle) {
    let url = scratch.appending(path: "capture-\(UUID().uuidString)")
    try Data().write(to: url)
    return (url, try FileHandle(forWritingTo: url))
  }

  /// The agent's own scratch copies: none is left behind.
  private func agentCopies() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: scratch.path)
      .filter { $0.hasPrefix("ferry-transfer-") }
  }

  @Test(arguments: [
    (ConnectionMethod.usbADB, true), (.wifiADB, true), (.usbFileTransfer, false),
  ])
  func onlyADeviceServedOverADBHasTools(method: ConnectionMethod, has: Bool) {
    let info = DeviceInfo(id: device, manufacturer: "", model: "LinkRunner-100G")
    let storage = StorageInfo(
      id: StorageID(device: device, key: "internal"), description: "Internal", capacity: 1, free: 1)
    let ready = AttachedDevice(info: info, state: .ready([storage]), method: method)
    #expect((ADBTools.target(for: device, devices: [ready], session: serial) != nil) == has)
    let ejected = AttachedDevice(info: info, state: .ejected, method: method)
    #expect(ADBTools.target(for: device, devices: [ejected], session: serial) == nil)
    #expect(ADBTools.target(for: device, devices: [ready], session: nil) == nil)
  }

  /// The route the open session uses, whatever a later scan would pick.
  @Test func toolsUseTheSessionsRoute() {
    let info = DeviceInfo(id: device, manufacturer: "", model: "LinkRunner-100G")
    let ready = AttachedDevice(info: info, state: .ready([]), method: .wifiADB)
    #expect(
      ADBTools.target(for: device, devices: [ready], session: "192.0.2.5:5555")
        == "192.0.2.5:5555")
  }

  // MARK: Screenshot

  @Test func aScreenshotGoesIntoTheClientsFile() async throws {
    let fake = FakeToolDevice()
    let (url, handle) = try destination()
    #expect(try await makeTools(fake).screenshot(device, into: handle.fileDescriptor) == .done)
    #expect(try Data(contentsOf: url) == FakeToolDevice.png)
    #expect(await fake.screenshots == [serial])
    #expect(try agentCopies().isEmpty)
  }

  /// adbd's `exec:` carries stderr with the image: text before the PNG signature is dropped.
  @Test func textBeforeTheImageIsDropped() async throws {
    let fake = FakeToolDevice()
    await fake.set {
      $0.image = Data("WARNING: linker: unused DT entry\n".utf8) + FakeToolDevice.png
    }
    let (url, handle) = try destination()
    #expect(try await makeTools(fake).screenshot(device, into: handle.fileDescriptor) == .done)
    #expect(try Data(contentsOf: url) == FakeToolDevice.png)
  }

  @Test(arguments: [
    Data("/system/bin/sh: screencap: not found\n".utf8),
    Data(repeating: 0x20, count: 4097) + FakeToolDevice.png, Data(),
  ])
  func somethingOtherThanAnImageIsNotWritten(output: Data) async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.image = output }
    let (url, handle) = try destination()
    #expect(
      try await makeTools(fake).screenshot(device, into: handle.fileDescriptor)
        == .failed(.noImage))
    #expect(try Data(contentsOf: url).isEmpty)
  }

  @Test func aDeviceNotOnADBGetsNoTools() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake, served: false)
    let (_, handle) = try destination()
    #expect(try await tools.screenshot(device, into: handle.fileDescriptor) == .failed(.notOverADB))
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
    await fake.set { $0.failure = .deviceGone(serial) }
    let (_, handle) = try destination()
    await #expect(throws: TransportError.deviceDisconnected) {
      try await makeTools(fake).screenshot(device, into: handle.fileDescriptor)
    }
  }

  // MARK: APK

  /// The device's copy is journalled before it exists and dropped once it is removed.
  @Test func anAPKIsCheckedInstalledAndItsCopyRemoved() async throws {
    let fake = FakeToolDevice()
    let journal = journal
    await fake.set { fake in
      fake.onCreate = { path in #expect(await journal.paths(on: device) == [path]) }
    }
    let apk = ZipFixture.archive(["classes.dex", "AndroidManifest.xml", "res/layout/a.xml"])
    let handle = try source(apk)
    // A client's offset is not trusted.
    try handle.seekToEnd()
    let outcome = try await makeTools(fake).installAPK(handle.fileDescriptor, on: device) { _, _ in
      true
    }
    #expect(outcome == .done)
    let installs = await fake.installs
    #expect(installs.map(\.contents) == [apk])
    let path = try #require(installs.first?.path)
    #expect(ADBDeviceTools.isTemporaryPath(path) && path.hasSuffix(".apk"))
    #expect(await fake.removals == [path])
    #expect(await journal.paths(on: device).isEmpty)
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
    #expect(await journal.paths(on: device).isEmpty)
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

  @Test func pmsRefusalIsPassedOnAndTheCopyRemoved() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.installResult = .failed("INSTALL_FAILED_VERSION_DOWNGRADE") }
    let handle = try source(ZipFixture.archive(["AndroidManifest.xml"]))
    #expect(
      try await makeTools(fake).installAPK(handle.fileDescriptor, on: device) { _, _ in true }
        == .failed(.installFailed("INSTALL_FAILED_VERSION_DOWNGRADE")))
    #expect(await fake.removals.count == 1)
    #expect(await journal.paths(on: device).isEmpty)
  }

  /// The device went away: its copy cannot be removed, so it stays journalled for the next
  /// session, which removes it.
  @Test func aCopyThatCannotBeRemovedIsSweptNextSession() async throws {
    let fake = FakeToolDevice()
    await fake.set {
      $0.failure = .connectionClosed
      $0.removes = false
    }
    let handle = try source(ZipFixture.archive(["AndroidManifest.xml"]))
    await #expect(throws: TransportError.deviceDisconnected) {
      try await makeTools(fake).installAPK(handle.fileDescriptor, on: device) { _, _ in true }
    }
    let left = try #require(await fake.removals.first)
    #expect(await journal.paths(on: device) == [left])
    #expect(try agentCopies().isEmpty)
    // A restarted agent reads the journal back, and the next session removes the file.
    let restarted = ToolJournal(store: scratch.appending(path: "journal.json"))
    #expect(await restarted.paths(on: device) == [left])
    await fake.set { $0.removes = true }
    await restarted.sweep(device, serial: serial, using: fake)
    #expect(await fake.removals == [left, left])
    #expect(await restarted.paths(on: device).isEmpty)
    #expect(
      await ToolJournal(store: scratch.appending(path: "journal.json")).paths(on: device).isEmpty)
  }
}
