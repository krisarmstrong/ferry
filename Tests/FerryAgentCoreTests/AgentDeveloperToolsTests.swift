import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The developer tools' requests as the agent answers them.
@Suite(.timeLimit(.minutes(1)))
struct AgentDeveloperToolsTests {
  private let device = DeviceID(serial: "0123456789abcdef")
  private let stream = UUID()
  private let route = "0123456789abcdef"

  private func service(_ harness: AgentHarness, _ fake: FakeToolDevice) -> AgentService {
    var limits = ADBTools.Limits()
    limits.logInterval = .milliseconds(1)
    let tools = ADBTools(
      device: fake, target: { _ in ADBRoute(serial: "0123456789abcdef") },
      journal: ToolJournal(store: harness.scratch.appending(path: "journal.json")),
      scratch: harness.scratch, limits: limits)
    return AgentService(
      hub: harness.hub, domains: harness.controller, scratch: harness.scratch, tools: tools)
  }

  private var requests: [AgentRequest] {
    [
      .startLogcat(device, stream: stream), .stopLogcat(device, stream: stream),
      .forwards(device),
      .addForward(device, PortForward(local: 8080, remote: 80)),
      .removeForward(device, local: 8080), .deviceInfo(device), .shellTarget(device),
    ]
  }

  @Test func theyTakeNoFile() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    for request in requests {
      let file = try harness.readable("x", "x")
      #expect(
        await harness.service.handle(request, file: file)
          == .failure(.io(String(localized: AgentText.badRequest))))
    }
  }

  @Test func withoutAdbTheyAreUnavailable() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    for request in requests where request != .stopLogcat(device, stream: stream) {
      let response = await harness.service.handle(
        request, file: nil, progress: { _, _ in }, logs: { _ in true })
      #expect(response == .toolFailed(.notOverADB))
    }
    #expect(await harness.service.handle(.stopLogcat(device, stream: stream), file: nil) == .done)
  }

  /// A log stream is sent to the client that asked: with nowhere to send it, the request is bad.
  @Test func aLogStreamNeedsASink() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let service = service(harness, FakeToolDevice())
    #expect(
      await service.handle(.startLogcat(device, stream: stream), file: nil)
        == .failure(.io(String(localized: AgentText.badRequest))))
  }

  @Test func aLogStreamRunsUntilTheDeviceEndsIt() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let service = service(harness, fake)
    let received = ReceivedBatches()
    let run = Task {
      await service.handle(
        .startLogcat(device, stream: stream), file: nil, progress: { _, _ in },
        logs: { batch in
          await received.add(batch)
          return true
        })
    }
    await log.send(["a", "b"])
    await log.end()
    #expect(await run.value == .done)
    #expect(await received.lines == ["a", "b"])
  }

  @Test func stopEndsTheStream() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let service = service(harness, fake)
    let run = Task {
      await service.handle(
        .startLogcat(device, stream: stream), file: nil, progress: { _, _ in }, logs: { _ in true })
    }
    #expect(try await eventually { await fake.logcatsOpened.count == 1 })
    #expect(await service.handle(.stopLogcat(device, stream: stream), file: nil) == .done)
    #expect(await run.value == .done)
  }

  @Test func forwardsInfoAndShellAreAnswered() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let fake = FakeToolDevice()
    let service = service(harness, fake)
    #expect(
      await service.handle(.addForward(device, PortForward(local: 8080, remote: 80)), file: nil)
        == .done)
    #expect(
      await service.handle(.forwards(device), file: nil)
        == .forwards([PortForward(local: 8080, remote: 80)]))
    #expect(await service.handle(.removeForward(device, local: 8080), file: nil) == .done)
    #expect(await service.handle(.forwards(device), file: nil) == .forwards([]))
    #expect(await service.handle(.deviceInfo(device), file: nil) == .deviceInfo(await fake.info))
    #expect(
      await service.handle(.shellTarget(device), file: nil)
        == .shellTarget(ShellTarget(adb: "/opt/homebrew/bin/adb", serial: route)!))
  }

  @Test func theServiceRefusesAForwardTheRulesRefuse() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let service = service(harness, FakeToolDevice())
    #expect(
      await service.handle(.addForward(device, PortForward(local: 22, remote: 22)), file: nil)
        == .toolFailed(.invalidPort))
  }
}

private actor ReceivedBatches {
  private var batches: [LogBatch] = []
  var lines: [String] { batches.flatMap(\.lines) }
  func add(_ batch: LogBatch) { batches.append(batch) }
}
