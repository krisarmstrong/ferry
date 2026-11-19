import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

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
      device: fake, target: { _ in serial },
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
}
