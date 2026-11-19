import DeviceKit
import FerryIPC
import Foundation

/// The developer tools: a log window, Open Shell, port forwarding and Device Info, for a device
/// Ferry serves over ADB. Each window has a session of its own that talks to the agent.
extension AppModel {
  func logcatSession(for device: DeviceID) -> LogcatSession {
    LogcatSession(device: device, model: modelName(of: device), client: client, services: services)
  }

  func portForwardsSession(for device: DeviceID) -> PortForwardsSession {
    PortForwardsSession(device: device, client: client)
  }

  func deviceInfoSession(for device: DeviceID) -> DeviceInfoSession {
    DeviceInfoSession(device: device, client: client, services: services)
  }

  /// The name the windows show for `device`: its model, as the menu shows it.
  func modelName(of device: DeviceID) -> String {
    devices.first { $0.id == device }?.info.model ?? ""
  }

  /// Open Shell: asks the agent for the `adb` it found and the serial of the route it serves the
  /// device by, writes a script that runs `adb -s <serial> shell` (see `ShellLaunch`), and opens
  /// it in Terminal.
  public func openShell(on device: DeviceID) async {
    ShellLaunch.sweep()
    guard let response = await sendTool(.shellTarget(device), file: nil),
      case .shellTarget(let target) = response
    else { return }
    let script: URL
    do {
      script = try ShellLaunch.prepare(target)
    } catch {
      actionError = DevicePresentation.terminalFailure
      return
    }
    if await !services.openInTerminal(script) {
      ShellLaunch.remove(script)
      actionError = DevicePresentation.terminalFailure
    }
  }
}
