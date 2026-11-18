import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The tool requests as the agent answers them.
@Suite(.timeLimit(.minutes(1)))
struct AgentToolsTests {
  private let device = DeviceID(serial: "0123456789abcdef")

  private func service(_ harness: AgentHarness, _ fake: FakeToolDevice, folder: URL)
    -> AgentService
  {
    let tools = ADBTools(
      device: fake,
      target: { _ in ADBTools.Target(serial: "0123456789abcdef", model: "LinkRunner-100G") },
      folder: { folder }, desktop: folder, scratch: harness.scratch)
    return AgentService(
      hub: harness.hub, domains: harness.controller, scratch: harness.scratch, tools: tools)
  }

  @Test func withoutAdbTheToolsAreUnavailable() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    #expect(
      await harness.service.handle(.screenshot(device), file: nil) == .toolFailed(.notOverADB))
    #expect(
      await harness.service.handle(.startRecording(device), file: nil) == .toolFailed(.notOverADB))
    #expect(
      await harness.service.handle(.stopRecording(device), file: nil)
        == .toolFailed(.notRecording))
    let apk = try harness.readable("a.apk", "x")
    #expect(
      await harness.service.handle(.installAPK(device, name: "a.apk"), file: apk)
        == .toolFailed(.notOverADB))
  }

  /// The app comes as a descriptor, never a path; a request without one is refused.
  @Test func anInstallNeedsItsFile() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    #expect(
      await harness.service.handle(.installAPK(device, name: "a.apk"), file: nil)
        == .failure(.io("bad request")))
    let file = try harness.readable("x", "x")
    #expect(
      await harness.service.handle(.screenshot(device), file: file) == .failure(.io("bad request")))
  }

  @Test func theAppsNameMustBeOneComponent() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let apk = try harness.readable("a.apk", "x")
    #expect(
      await harness.service.handle(.installAPK(device, name: "../a.apk"), file: apk)
        == .failure(.invalidName("../a.apk")))
  }

  @Test func anInstallIsListedAsATransferAndReportsProgress() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let folder = try TestScratch.folder("agent-captures")
    let fake = FakeToolDevice()
    let service = service(harness, fake, folder: folder)
    let url = try harness.file("app.apk", "")
    try ZipFixture.archive(["AndroidManifest.xml"]).write(to: url)
    let response = await service.handle(
      .installAPK(device, name: "app.apk"), file: try FileHandle(forReadingFrom: url)
    ) { _, _ in }
    #expect(response == .done)
    #expect(await fake.installs.count == 1)
  }

  @Test func aScreenshotRepliesWithItsFile() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let folder = try TestScratch.folder("agent-captures")
    let service = service(harness, FakeToolDevice(), folder: folder)
    guard case .saved(let url) = await service.handle(.screenshot(device), file: nil) else {
      Issue.record("no file")
      return
    }
    #expect(url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    #expect(url.pathExtension == "png")
  }

  @Test func statusShowsARecordingUntilItIsSaved() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let folder = try TestScratch.folder("agent-captures")
    let service = service(harness, FakeToolDevice(), folder: folder)
    let recording = Task { await service.handle(.startRecording(device), file: nil) }
    var running: [ActiveRecording] = []
    let deadline = ContinuousClock.now + .seconds(5)
    while running.isEmpty, ContinuousClock.now < deadline {
      guard case .status(let report) = await service.handle(.status, file: nil) else { break }
      running = report.recordings
    }
    #expect(running.map(\.device) == [device])
    #expect(await service.handle(.stopRecording(device), file: nil) == .done)
    guard case .saved(let url) = await recording.value else {
      Issue.record("no file")
      return
    }
    #expect(url.pathExtension == "mp4")
    guard case .status(let report) = await service.handle(.status, file: nil) else { return }
    #expect(report.recordings.isEmpty)
  }
}
