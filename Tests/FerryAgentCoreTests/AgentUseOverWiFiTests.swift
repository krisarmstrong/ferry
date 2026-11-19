import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing
import os

@testable import FerryAgentCore

/// Use over Wi-Fi restarts adbd, which cuts off whatever runs over ADB on the device: it is
/// refused while the device has a log stream or a recording running.
@Suite(.timeLimit(.minutes(1)))
struct AgentUseOverWiFiTests {
  static let linkRunner = WirelessADBTests.linkRunner
  var serial: String { Self.linkRunner.id.serial }

  /// A unit on USB debugging that has a network address and no TCP port yet.
  private func usbUnit() async -> FakeWirelessADB {
    let adb = FakeWirelessADB()
    let serial = serial
    await adb.set {
      $0.listed[serial] = .device
      $0.usb[serial] = .init(info: Self.linkRunner)
      $0.addresses[serial] = ["192.0.2.40"]
      $0.units["192.0.2.40:5555"] = .init(info: Self.linkRunner)
    }
    return adb
  }

  private func service(
    _ harness: AgentHarness, _ adb: FakeWirelessADB, _ fake: FakeToolDevice
  ) -> AgentService {
    let serial = serial
    let tools = ADBTools(
      device: fake, target: { _ in ADBRoute(serial: serial) },
      journal: ToolJournal(store: harness.scratch.appending(path: "journal.json")),
      scratch: harness.scratch)
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: WirelessADBTests.fast)
    return AgentService(
      hub: harness.hub, domains: harness.controller, scratch: harness.scratch, wireless: wireless,
      tools: tools)
  }

  @Test func aDeviceStreamingItsLogIsNotRestarted() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let adb = await usbUnit()
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let service = service(harness, adb, fake)
    let streaming = Task {
      await service.handle(
        .startLogcat(Self.linkRunner.id, stream: UUID()), file: nil, progress: { _, _ in },
        logs: { _ in true })
    }
    #expect(try await eventually { await fake.logcatsOpened.count == 1 })
    #expect(
      await service.handle(.enableWireless(Self.linkRunner.id), file: nil)
        == .wireless(.failed(.deviceInUse)))
    #expect(await adb.calls.isEmpty)
    await log.end()
    _ = await streaming.value
    #expect(
      await service.handle(.enableWireless(Self.linkRunner.id), file: nil)
        == .wireless(.connected))
  }

  @Test func aDeviceRecordingItsScreenIsNotRestarted() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let adb = await usbUnit()
    let fake = FakeToolDevice()
    let service = service(harness, adb, fake)
    let recording = Task { await service.handle(.startRecording(Self.linkRunner.id), file: nil) }
    #expect(try await eventually { await !fake.recordingsStarted.isEmpty })
    #expect(
      await service.handle(.enableWireless(Self.linkRunner.id), file: nil)
        == .wireless(.failed(.deviceInUse)))
    #expect(await adb.calls.isEmpty)
    await fake.recording.end()
    _ = await recording.value
  }

  @Test func aDeviceWithATransferRunningIsNotRestarted() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let adb = await usbUnit()
    let service = service(harness, adb, FakeToolDevice())
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let transfer = Task {
      try await service.transfers.track(
        ActiveTransfer(
          device: Self.linkRunner.id, name: "a.bin", direction: .toDevice, completed: 0,
          total: 1),
        report: { _, _ in },
        { (_) async throws(TransportError) in
          for await _ in released { break }
        })
    }
    #expect(try await eventually { await !service.transfers.list().isEmpty })
    #expect(
      await service.handle(.enableWireless(Self.linkRunner.id), file: nil)
        == .wireless(.failed(.deviceInUse)))
    #expect(await adb.calls.isEmpty)
    release.yield()
    try await transfer.value
  }
}

/// While a device's adb restarts for Use over Wi-Fi, a transfer that starts on it waits for the
/// restart to finish instead of being cut off by it.
@Suite(.timeLimit(.minutes(1)))
struct TransferBoardRestartTests {
  let device = DeviceID(serial: "0123456789abcdef")

  private func start(_ board: TransferBoard, ran: OSAllocatedUnfairLock<Bool>) -> Task<
    Void, any Error
  > {
    Task {
      try await board.track(
        ActiveTransfer(device: device, name: "a", direction: .toMac, completed: 0, total: 1),
        report: { _, _ in },
        { (_) async throws(TransportError) in ran.withLock { $0 = true } })
    }
  }

  @Test func aTransferWaitsForTheRestart() async throws {
    let board = TransferBoard()
    #expect(await board.beginRestart(device))
    let ran = OSAllocatedUnfairLock(initialState: false)
    let transfer = start(board, ran: ran)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!ran.withLock { $0 })
    await board.endRestart(device)
    try await transfer.value
    #expect(ran.withLock { $0 })
  }

  @Test func aRestartWaitsForNoTransferOnTheDevice() async throws {
    let board = TransferBoard()
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let transfer = Task {
      try await board.track(
        ActiveTransfer(device: device, name: "a", direction: .toMac, completed: 0, total: 1),
        report: { _, _ in },
        { (_) async throws(TransportError) in
          for await _ in released { break }
        })
    }
    #expect(try await eventually { await !board.list().isEmpty })
    #expect(await !board.beginRestart(device))
    release.yield()
    try await transfer.value
    #expect(await board.beginRestart(device))
  }

  /// A transfer waiting for the restart that its client cancels ends at once, as cancelled,
  /// without waiting for the restart to finish.
  @Test func aCancelledWaitingTransferEndsAtOnce() async throws {
    let board = TransferBoard()
    #expect(await board.beginRestart(device))
    let cancellation = RequestCancellation()
    let ran = OSAllocatedUnfairLock(initialState: false)
    let transfer = Task {
      try await RequestCancellation.$current.withValue(cancellation) {
        try await start(board, ran: ran).value
      }
    }
    cancellation.cancel()
    await #expect(throws: TransportError.cancelled) { try await transfer.value }
    #expect(!ran.withLock { $0 })
    #expect(await board.list().isEmpty)
    await board.endRestart(device)
  }
}
