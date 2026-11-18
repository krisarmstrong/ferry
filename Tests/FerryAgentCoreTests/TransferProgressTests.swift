import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// Progress a request's transfer reports.
private final class Reports: Sendable {
  private let values = Mutex<[[UInt64]]>([])
  var all: [[UInt64]] { values.withLock { $0 } }
  func record(_ completed: UInt64, _ total: UInt64) {
    values.withLock { $0.append([completed, total]) }
  }
}

@Suite(.timeLimit(.minutes(1)))
struct TransferProgressTests {
  @Test func aFetchReportsItsBytesEndingWithTheWholeFile() async throws {
    let device = await makeDevice("A")
    try await device.seed(try path("/a.txt"), in: storageID(device), contents: Data("abc".utf8))
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let (_, handle) = try harness.writable("out", "")
    let reports = Reports()

    let reply = await harness.service.handle(
      .fetch(domain: domain, id: try await harness.id(try path("/a.txt"), in: domain)),
      file: handle, progress: reports.record)

    #expect(reply == .done)
    #expect(reports.all.last == [3, 3])
    guard case .status(let report) = await harness.service.handle(.status, file: nil) else {
      Issue.record("expected a status")
      return
    }
    #expect(report.transfers.isEmpty)
  }

  @Test func anUploadReportsToTheClient() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let reports = Reports()

    let reply = await harness.service.handle(
      .create(domain: domainID(device), parent: .root, name: "b.txt", isFolder: false),
      file: try harness.readable("b.txt", "hello"), progress: reports.record)

    guard case .entry = reply else {
      Issue.record("expected an entry, got \(reply)")
      return
    }
    #expect(reports.all.last == [5, 5])
  }

  /// The menu lists a transfer while it runs, with the bytes reported so far.
  @Test func theBoardListsATransferWhileItRuns() async throws {
    let board = TransferBoard()
    let start = ActiveTransfer(
      device: DeviceID(serial: "A"), name: "big.bin", direction: .toDevice, completed: 0,
      total: 0)
    let (gate, open) = AsyncStream.makeStream(of: Void.self)
    let running = Task {
      let ignore: TransferProgressHandler = { _, _ in }
      try await board.track(start, report: ignore) { progress throws(TransportError) in
        _ = progress(40, 100)
        for await _ in gate {}
      }
    }
    var listed: [ActiveTransfer] = []
    for _ in 0..<2_000 {
      listed = await board.list()
      if listed.first?.completed == 40 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(listed.map(\.percent) == [40])
    #expect(listed.first?.name == "big.bin")
    open.finish()
    try await running.value
    #expect(await board.list().isEmpty)
  }
}
