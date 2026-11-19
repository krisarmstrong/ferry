import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

private let device = DeviceID(serial: "0123456789abcdef")
private let serial = "192.0.2.31:5555"

/// Port forwards, device info and the shell's target: only for a device served over ADB, by the
/// route its session uses, with the ports checked here and not only on screen.
@Suite(.timeLimit(.minutes(1)))
struct ADBToolsDeveloperTests {
  let scratch: URL
  let journal: ToolJournal

  init() throws {
    scratch = try TestScratch.folder("developer-scratch")
    journal = ToolJournal(store: scratch.appending(path: "journal.json"))
  }

  private func makeTools(_ fake: FakeToolDevice, served: Bool = true) -> ADBTools {
    ADBTools(
      device: fake, target: { _ in served ? ADBRoute(serial: serial) : nil }, journal: journal,
      scratch: scratch)
  }

  // MARK: Forwards

  @Test func theListIsTheDevicesForwards() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.forwardList = [PortForward(local: 8080, remote: 80)] }
    #expect(
      try await makeTools(fake).forwards(device)
        == .success([PortForward(local: 8080, remote: 80)]))
  }

  @Test func aForwardIsAddedOnTheSessionsRoute() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake)
    #expect(try await tools.addForward(device, PortForward(local: 8080, remote: 80)) == .done)
    #expect(await fake.forwardCalls == ["add \(serial) 8080 80"])
  }

  /// A port below 1024 on the Mac, or a port 0, is refused before anything reaches the device.
  @Test(arguments: [
    PortForward(local: 80, remote: 80), PortForward(local: 1023, remote: 80),
    PortForward(local: 0, remote: 80), PortForward(local: 8080, remote: 0),
  ])
  func aForwardTheRulesRefuseNeverReachesTheDevice(forward: PortForward) async throws {
    let fake = FakeToolDevice()
    #expect(try await makeTools(fake).addForward(device, forward) == .failed(.invalidPort))
    #expect(await fake.forwardCalls.isEmpty)
  }

  /// adb's refusal (a port that is taken) is shown in adb's words, bounded.
  @Test func adbsWordsComeBackWhenAPortIsTaken() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.failure = .failed("cannot bind listener: Address already in use") }
    #expect(
      try await makeTools(fake).addForward(device, PortForward(local: 8080, remote: 80))
        == .failed(.forwardFailed("cannot bind listener: Address already in use")))
    await fake.set { $0.failure = .failed(String(repeating: "x", count: 500)) }
    #expect(
      try await makeTools(fake).addForward(device, PortForward(local: 8080, remote: 80))
        == .failed(.forwardFailed(String(repeating: "x", count: 200))))
  }

  @Test func aLostDeviceIsDisconnectedWhateverItWasAsked() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.failure = .deviceGone(serial) }
    let tools = makeTools(fake)
    await #expect(throws: TransportError.deviceDisconnected) { try await tools.forwards(device) }
    await #expect(throws: TransportError.deviceDisconnected) {
      try await tools.addForward(device, PortForward(local: 8080, remote: 80))
    }
    await #expect(throws: TransportError.deviceDisconnected) { try await tools.deviceInfo(device) }
  }

  @Test func aForwardIsRemovedByItsLocalPort() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.forwardList = [PortForward(local: 8080, remote: 80)] }
    #expect(try await makeTools(fake).removeForward(device, local: 8080) == .done)
    #expect(await fake.forwardCalls == ["remove \(serial) 8080"])
  }

  /// adb removes a forward by its Mac port whichever device owns it, so Ferry removes only one
  /// the list shows for this device.
  @Test func aForwardThatIsNotThisDevicesIsNotRemoved() async throws {
    let fake = FakeToolDevice()
    #expect(
      try await makeTools(fake).removeForward(device, local: 8080)
        == .failed(.forwardNotFound))
    #expect(await fake.forwardCalls.isEmpty)
  }

  /// The device went between the list and the request: a lost device, not a refused forward.
  @Test func aDeviceThatLeftBetweenTheListAndTheRequestIsDisconnected() async throws {
    let fake = FakeToolDevice()
    await fake.set {
      $0.forwardList = [PortForward(local: 8080, remote: 80)]
      $0.removeFailure = .failed("device '192.0.2.31:5555' not found")
    }
    await #expect(throws: TransportError.deviceDisconnected) {
      try await makeTools(fake).removeForward(device, local: 8080)
    }
  }

  /// Another tool removed the forward first: it is gone, which is what was asked.
  @Test func aForwardAnotherToolRemovedFirstIsReportedGone() async throws {
    let fake = FakeToolDevice()
    await fake.set {
      $0.forwardList = [PortForward(local: 8080, remote: 80)]
      $0.removeFailure = .failed("listener 'tcp:8080' not found")
    }
    #expect(
      try await makeTools(fake).removeForward(device, local: 8080) == .failed(.forwardNotFound))
  }

  // MARK: Info and shell

  @Test func theInfoIsTheDevices() async throws {
    let fake = FakeToolDevice()
    let info = try await makeTools(fake).deviceInfo(device)
    #expect(info == .success(await fake.info))
  }

  @Test func theShellTargetIsTheLocatedAdbAndTheSessionsRoute() async throws {
    let fake = FakeToolDevice()
    #expect(
      try await makeTools(fake).shellTarget(device)
        == .success(ShellTarget(adb: "/opt/homebrew/bin/adb", serial: serial)!))
  }

  @Test func withoutAdbThereIsNoShell() async throws {
    let fake = FakeToolDevice()
    fake.adbLocation.set(nil)
    #expect(try await makeTools(fake).shellTarget(device) == .failure(.adbNotFound))
  }

  /// A serial that could be read as more than a serial is never put in a command.
  @Test(arguments: ["-s", "a b", "a;b", "a'b", ""])
  func aSerialThatIsNotPlainGetsNoShell(odd: String) async throws {
    let fake = FakeToolDevice()
    let tools = ADBTools(
      device: fake, target: { _ in ADBRoute(serial: odd) }, journal: journal, scratch: scratch)
    await #expect(throws: TransportError.self) { try await tools.shellTarget(device) }
  }

  @Test func aDeviceNotOnADBGetsNoneOfThem() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake, served: false)
    #expect(try await tools.forwards(device) == .failure(.notOverADB))
    #expect(
      try await tools.addForward(device, PortForward(local: 8080, remote: 80))
        == .failed(.notOverADB))
    #expect(try await tools.removeForward(device, local: 8080) == .failed(.notOverADB))
    #expect(try await tools.deviceInfo(device) == .failure(.notOverADB))
    #expect(try await tools.shellTarget(device) == .failure(.notOverADB))
    #expect(await fake.forwardCalls.isEmpty)
  }
}
