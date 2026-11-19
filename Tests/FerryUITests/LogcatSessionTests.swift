import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// The log window's state: what it shows as batches arrive, pause, clear, the filters, how it
/// ends, and Save.
@MainActor
struct LogcatSessionTests {
  let log = CallLog()
  let id = DeviceID(serial: "0123456789abcdef")
  let client: FakeClient
  let services: FakeServices

  init() {
    client = FakeClient(log: log)
    services = FakeServices(log: log)
  }

  private func session() -> LogcatSession {
    LogcatSession(device: id, model: "LinkRunner-100G", client: client, services: services)
  }

  /// Runs the session until `condition` holds, then stops it as closing the window does.
  private func running(
    _ session: LogcatSession, _ body: () async throws -> Void
  ) async throws {
    let run = Task { await session.run() }
    try await wait { log.all.contains("startLogcat \(id.serial)") }
    try await body()
    await session.close()
    await run.value
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
  }

  @Test func batchesAreShownInOrder() async throws {
    let session = session()
    try await running(session) {
      await client.push(LogBatch(lines: ["one", "two"], skipped: 0))
      await client.push(LogBatch(lines: ["three"], skipped: 0))
      #expect(session.shown.map(\.text) == ["one", "two", "three"])
      #expect(session.state == .running)
    }
  }

  /// The agent dropped lines on the way (the app was too slow): the window says so where they
  /// would have been.
  @Test func skippedLinesAreMarked() async throws {
    let session = session()
    try await running(session) {
      await client.push(LogBatch(lines: ["a"], skipped: 0))
      await client.push(LogBatch(lines: ["b"], skipped: 120))
      let texts = session.shown.map(\.text)
      #expect(texts.count == 3)
      #expect(texts[0] == "a" && texts[2] == "b")
      #expect(texts[1].contains("120"))
    }
  }

  @Test func theLevelAndTextFiltersApplyToWhatIsHeldAndWhatArrives() async throws {
    let session = session()
    try await running(session) {
      await client.push(LogBatch(lines: LogcatLogTests.mixed, skipped: 0))
      #expect(session.shown.count == 7)
      session.minimumLevel = .error
      #expect(session.shown.count == 3)
      await client.push(
        LogBatch(
          lines: ["01-02 03:04:06.000  1  2 E Net: later", "01-02 03:04:06.001  1  2 I X: no"],
          skipped: 0))
      #expect(session.shown.count == 4)
      session.filterText = "later"
      #expect(session.shown.map(\.text) == ["01-02 03:04:06.000  1  2 E Net: later"])
      session.filterText = ""
      session.minimumLevel = .verbose
      #expect(session.shown.count == 9)
    }
  }

  /// Paused, the window stops moving, but nothing is lost: resuming shows what came meanwhile.
  @Test func pausingFreezesTheViewAndResumingCatchesUp() async throws {
    let session = session()
    try await running(session) {
      await client.push(LogBatch(lines: ["a"], skipped: 0))
      session.togglePause()
      #expect(session.isPaused)
      await client.push(LogBatch(lines: ["b", "c"], skipped: 0))
      #expect(session.shown.map(\.text) == ["a"])
      #expect(session.held == 3)
      session.togglePause()
      #expect(!session.isPaused)
      #expect(session.shown.map(\.text) == ["a", "b", "c"])
    }
  }

  @Test func clearEmptiesTheWindowAndTheBuffer() async throws {
    let session = session()
    try await running(session) {
      await client.push(LogBatch(lines: ["a", "b"], skipped: 0))
      session.clear()
      #expect(session.shown.isEmpty)
      #expect(session.held == 0)
      await client.push(LogBatch(lines: ["c"], skipped: 0))
      #expect(session.shown.map(\.text) == ["c"])
    }
  }

  @Test func clearWhilePausedClearsTheFrozenView() async throws {
    let session = session()
    try await running(session) {
      await client.push(LogBatch(lines: ["a"], skipped: 0))
      session.togglePause()
      session.clear()
      #expect(session.shown.isEmpty)
    }
  }

  @Test func theBufferHoldsFiftyThousandLines() async throws {
    let session = session()
    session.receive(LogBatch(lines: (0..<50_010).map { "line \($0)" }, skipped: 0))
    #expect(session.held == 50_000)
    #expect(session.shown.first?.text == "line 10")
  }

  @Test func closingStopsTheAgentsStream() async throws {
    let session = session()
    try await running(session) {}
    #expect(log.all.contains("stopLogcat \(id.serial)"))
  }

  @Test func aStreamTheDeviceEndsIsSaidToBeOver() async throws {
    let session = session()
    client.endStream(with: .done)
    await session.run()
    #expect(session.state == .ended("The device ended the log."))
  }

  @Test func aLostDeviceSaysSo() async throws {
    let session = session()
    client.endStream(with: .failure(.deviceDisconnected))
    await session.run()
    #expect(session.state == .ended(DevicePresentation.message(for: .deviceDisconnected)))
  }

  @Test func aDeviceWithoutDebuggingSaysSo() async throws {
    let session = session()
    client.endStream(with: .toolFailed(.notOverADB))
    await session.run()
    #expect(session.state == .ended(DevicePresentation.message(for: .notOverADB)))
  }

  // MARK: Save

  private func saveFolder() throws -> URL { try TestScratch.folder("log-save") }

  /// The app writes the file, never the agent, and what it writes is every held line that passes
  /// the filters, however the view is paused.
  @Test func saveWritesTheFilteredLinesAsPlainText() async throws {
    let session = session()
    let target = try saveFolder().appending(path: "log.txt")
    services.logDestination = target
    try await running(session) {
      await client.push(LogBatch(lines: LogcatLogTests.mixed, skipped: 0))
      session.minimumLevel = .error
      session.togglePause()
      await client.push(LogBatch(lines: ["01-02 03:04:06.000  1  2 E Net: later"], skipped: 0))
      await session.save()
    }
    let written = try String(contentsOf: target, encoding: .utf8)
    #expect(
      written
        == [
          LogcatLogTests.mixed[4], LogcatLogTests.mixed[5], LogcatLogTests.mixed[6],
          "01-02 03:04:06.000  1  2 E Net: later",
        ].joined(separator: "\n") + "\n")
    #expect(
      log.all.contains {
        $0.hasPrefix("chooseLogDestination Logcat LinkRunner-100G ") && $0.hasSuffix(".txt")
      })
  }

  @Test func cancellingTheSavePanelWritesNothing() async throws {
    let session = session()
    services.logDestination = nil
    try await running(session) {
      await client.push(LogBatch(lines: ["a"], skipped: 0))
      await session.save()
    }
    #expect(session.saveError == nil)
  }

  @Test func aFileThatCannotBeWrittenIsReported() async throws {
    let session = session()
    services.logDestination = URL(filePath: "/nonexistent-folder-for-ferry/log.txt")
    try await running(session) {
      await client.push(LogBatch(lines: ["a"], skipped: 0))
      await session.save()
    }
    #expect(session.saveError != nil)
  }
}
