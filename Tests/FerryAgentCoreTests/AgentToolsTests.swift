import ADBTransport
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

  private func service(_ harness: AgentHarness, _ fake: FakeToolDevice) -> AgentService {
    let tools = ADBTools(
      device: fake, target: { _ in ADBRoute(serial: "0123456789abcdef") },
      journal: ToolJournal(store: harness.scratch.appending(path: "journal.json")),
      scratch: harness.scratch)
    return AgentService(
      hub: harness.hub, domains: harness.controller, scratch: harness.scratch, tools: tools)
  }

  @Test func withoutAdbTheToolsAreUnavailable() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let (_, capture) = try harness.writable("shot", "")
    #expect(
      await harness.service.handle(.screenshot(device), file: capture) == .toolFailed(.notOverADB))
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

  /// Files travel as descriptors, never paths: a request without its file is refused, and so is
  /// one that takes none but came with one.
  @Test func eachToolTakesItsFileOrNone() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    for request: AgentRequest in [
      .installAPK(device, name: "a.apk"), .screenshot(device), .saveRecording(device),
    ] {
      #expect(
        await harness.service.handle(request, file: nil)
          == .failure(.io(String(localized: AgentText.badRequest))))
    }
    for request: AgentRequest in [
      .startRecording(device), .stopRecording(device), .discardRecording(device),
    ] {
      let file = try harness.readable("x", "x")
      #expect(
        await harness.service.handle(request, file: file)
          == .failure(.io(String(localized: AgentText.badRequest))))
    }
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
    let fake = FakeToolDevice()
    let service = service(harness, fake)
    let url = try harness.file("app.apk", "")
    try ZipFixture.archive(["AndroidManifest.xml"]).write(to: url)
    let response = await service.handle(
      .installAPK(device, name: "app.apk"), file: try FileHandle(forReadingFrom: url)
    ) { _, _ in }
    #expect(response == .done)
    #expect(await fake.installs.count == 1)
  }

  @Test func aScreenshotFillsTheAppsFile() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let service = service(harness, FakeToolDevice())
    let (url, capture) = try harness.writable("shot", "")
    #expect(await service.handle(.screenshot(device), file: capture) == .done)
    #expect(try Data(contentsOf: url) == FakeToolDevice.png)
  }

  @Test func statusShowsARecordingUntilItIsCollected() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let service = service(harness, FakeToolDevice())
    let recording = Task { await service.handle(.startRecording(device), file: nil) }
    var running: [ActiveRecording] = []
    let deadline = ContinuousClock.now + .seconds(5)
    while running.isEmpty, ContinuousClock.now < deadline {
      guard case .status(let report) = await service.handle(.status, file: nil) else { break }
      running = report.recordings
    }
    #expect(running.map(\.device) == [device])
    #expect(await service.handle(.stopRecording(device), file: nil) == .done)
    #expect(await recording.value == .done)
    guard case .status(let finished) = await service.handle(.status, file: nil) else { return }
    #expect(finished.recordings.map(\.finished) == [true])
    let (url, capture) = try harness.writable("video", "")
    #expect(await service.handle(.saveRecording(device), file: capture) == .done)
    #expect(try Data(contentsOf: url) == FakeRecording.mp4)
    guard case .status(let report) = await service.handle(.status, file: nil) else { return }
    #expect(report.recordings.isEmpty)
  }
}
