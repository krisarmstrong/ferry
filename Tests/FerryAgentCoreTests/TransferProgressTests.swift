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

    #expect(reply.isEntry)
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

/// A file whose listed size is stale downloads whole, and Finder's item then shows the size
/// that arrived, also after the folder is listed again with the stale size.
@Suite(.timeLimit(.minutes(1)))
struct StaleSizeFetchTests {
  @Test func aFileLongerThanListedIsFetchedAndKeepsItsRealSize() async throws {
    let device = await makeDevice("A")
    let storage = storageID(device)
    let file = try path("/.settings/global.o")
    try await device.seed(file, in: storage, contents: Data(count: 40))
    await device.reportSize(32, for: file)
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let id = try await harness.id(file, in: domain)
    let (target, handle) = try harness.writable("out", "")

    let reply = await harness.service.handle(.fetch(domain: domain, id: id), file: handle)

    guard case .entry(let entry) = reply else {
      Issue.record("expected the fetched item, got \(reply)")
      return
    }
    #expect(entry.id == id)
    #expect(entry.item.size == 40)
    #expect(try Data(contentsOf: target).count == 40)
    let settings = try await harness.id(try path("/.settings"), in: domain)
    guard
      case .page(let listed, _) = await harness.service.handle(
        .list(domain: domain, folder: settings), file: nil)
    else {
      Issue.record("expected a listing")
      return
    }
    #expect(listed.map(\.item.size) == [40])
  }
}
