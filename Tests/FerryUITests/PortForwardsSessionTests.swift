import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// The port forwarding window: the list, adding with the ports checked before anything is sent,
/// removing, and adb's words when a port is taken.
@MainActor
struct PortForwardsSessionTests {
  let log = CallLog()
  let id = DeviceID(serial: "0123456789abcdef")
  let client: FakeClient

  init() {
    client = FakeClient(log: log)
  }

  private func session() -> PortForwardsSession {
    PortForwardsSession(device: id, client: client)
  }

  @Test func theListIsLoaded() async {
    client.forwardList.withLock { $0 = [PortForward(local: 8080, remote: 80)] }
    let session = session()
    await session.refresh()
    #expect(session.forwards == [PortForward(local: 8080, remote: 80)])
    #expect(session.error == nil)
  }

  @Test func addingSendsTheChosenPortsThenShowsTheList() async {
    let session = session()
    session.localPort = " 8080 "
    session.remotePort = "80"
    await session.add()
    #expect(log.all.contains("addForward \(id.serial) 8080 80"))
    #expect(session.forwards == [PortForward(local: 8080, remote: 80)])
    #expect(session.localPort.isEmpty && session.remotePort.isEmpty)
    #expect(session.error == nil)
  }

  /// A port that is not a number, is out of range, or is below 1024 on the Mac is refused here:
  /// nothing is sent.
  @Test(arguments: [
    ("abc", "80"), ("8080", ""), ("", "80"), ("80", "80"), ("1023", "80"), ("0", "80"),
    ("8080", "0"), ("65536", "80"), ("8080", "65536"), ("-1", "80"), ("80 80", "80"),
    ("8080.5", "80"),
  ])
  func portsTheRulesRefuseAreNeverSent(local: String, remote: String) async {
    let session = session()
    session.localPort = local
    session.remotePort = remote
    await session.add()
    #expect(!log.all.contains { $0.hasPrefix("addForward") })
    #expect(session.error == DevicePresentation.message(for: .invalidPort))
    #expect(session.localPort == local)
  }

  @Test func theEdgesOfTheRangeAreAllowed() async {
    let session = session()
    session.localPort = "1024"
    session.remotePort = "65535"
    await session.add()
    #expect(log.all.contains("addForward \(id.serial) 1024 65535"))
    #expect(session.error == nil)
  }

  @Test func adbsWordsAreShownWhenAPortIsTaken() async {
    client.forwardReply.withLock {
      $0 = .toolFailed(.forwardFailed("cannot bind listener: Address already in use"))
    }
    let session = session()
    session.localPort = "8080"
    session.remotePort = "80"
    await session.add()
    #expect(
      session.error
        == "adb couldn't forward the port: cannot bind listener: Address already in use")
    // The fields stay, so the user can change a port and try again.
    #expect(session.localPort == "8080")
  }

  /// adb's words come from a program, so a control character in them is shown escaped.
  @Test func adbsWordsAreEscaped() async {
    client.forwardReply.withLock { $0 = .toolFailed(.forwardFailed("bad \u{1B}[31m port")) }
    let session = session()
    session.localPort = "8080"
    session.remotePort = "80"
    await session.add()
    #expect(session.error?.contains("\u{1B}") == false)
    #expect(session.error?.contains("\\u{1B}") == true)
  }

  @Test func removingSendsTheLocalPortThenShowsTheList() async {
    client.forwardList.withLock {
      $0 = [PortForward(local: 8080, remote: 80), PortForward(local: 9090, remote: 90)]
    }
    let session = session()
    await session.refresh()
    await session.remove(PortForward(local: 8080, remote: 80))
    #expect(log.all.contains("removeForward \(id.serial) 8080"))
    #expect(session.forwards == [PortForward(local: 9090, remote: 90)])
  }

  @Test func aLostDeviceIsShownAsAnError() async {
    let session = PortForwardsSession(device: id, client: UnreachableClient())
    await session.refresh()
    #expect(session.error == DevicePresentation.message(for: .deviceDisconnected))
  }
}
