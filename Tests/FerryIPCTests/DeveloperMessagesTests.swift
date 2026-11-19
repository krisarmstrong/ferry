import DeviceKit
import Foundation
import Testing

@testable import FerryIPC

private let device = DeviceID(serial: "R58N12345")
private let stream = UUID()

func developerRequests() -> [AgentRequest] {
  [
    .startLogcat(device, stream: stream), .stopLogcat(device, stream: stream), .forwards(device),
    .addForward(device, PortForward(local: 8080, remote: 80)),
    .removeForward(device, local: 8080), .deviceInfo(device), .shellTarget(device),
  ]
}

/// Logcat, a shell, port forwards and device info reach into the user's devices: the app's alone.
@Test func developerToolRequestsAreTheAppsAlone() {
  for request in developerRequests() {
    #expect(ClientRole.app.allows(request))
    #expect(!ClientRole.provider.allows(request))
  }
}

/// A shell target becomes a command in Terminal, so one that could be read as something other
/// than a path and a serial never decodes: the agent's reply is checked again on the app's side.
@Test(arguments: [
  ("/opt/homebrew/bin/adb", "0123456789abcdef", true),
  ("/opt/homebrew/bin/adb", "192.0.2.31:5555", true),
  ("/Users/me/Library/Android/sdk/platform-tools/adb", "adb-0A17-AbCd._adb-tls-connect._tcp", true),
  ("adb", "S", false), ("", "S", false), ("/opt/adb\nrm -rf ~", "S", false),
  ("/opt/adb\u{0}", "S", false), ("/opt/adb", "", false), ("/opt/adb", "-s", false),
  ("/opt/adb", "S; reboot", false), ("/opt/adb", "S T", false), ("/opt/adb", "S'T", false),
  ("/opt/adb", "S$(x)", false), ("/opt/adb", "S\nT", false), ("/opt/adb", "é", false),
  ("/opt/adb", String(repeating: "a", count: 129), false),
])
func shellTargetsAreValidated(adb: String, serial: String, valid: Bool) throws {
  #expect((ShellTarget(adb: adb, serial: serial) != nil) == valid)
  let json = try #require(
    String(
      data: JSONEncoder().encode(["adb": adb, "serial": serial]), encoding: .utf8))
  let decoded = try? JSONDecoder().decode(ShellTarget.self, from: Data(json.utf8))
  #expect((decoded != nil) == valid)
}
