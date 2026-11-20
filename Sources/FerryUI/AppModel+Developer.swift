import DeviceKit
import FerryIPC
import Foundation

/// The developer tools: a log window, Open in Terminal and port forwarding, for a device Ferry
/// serves over ADB. The log window and each device's forwards have a session of their own that
/// talks to the agent.
extension AppModel {
  func logcatSession(for device: DeviceID) -> LogcatSession {
    LogcatSession(
      device: device, name: fileName(of: device), client: client, services: services)
  }

  /// The forwards the expanded device's open Port Forwarding disclosure shows; `nil` while it
  /// is closed.
  func openForwards(of device: DeviceID) -> PortForwardsSession? {
    guard forwardsOpen == device, isExpanded(.device(device)) else { return nil }
    return forwardSessions[device]
  }

  /// Opens the expanded device's Port Forwarding, reading its list again, or closes it.
  func toggleForwards(of device: DeviceID) async {
    guard openForwards(of: device) == nil, isExpanded(.device(device)) else {
      forwardsOpen = nil
      return
    }
    let session = forwardSessions[device] ?? PortForwardsSession(device: device, client: client)
    forwardSessions[device] = session
    forwardsOpen = device
    await session.refresh()
  }

  func forgetForwardsOfGoneDevices() {
    let listed = Set(devices.map(\.id))
    forwardSessions = forwardSessions.filter { listed.contains($0.key) }
    if let open = forwardsOpen, !listed.contains(open) { forwardsOpen = nil }
  }

  /// The name the windows show for `device`, as the menu shows it: two units of one model are
  /// told apart by the end of their serials. Escaped; empty for a device no longer listed.
  func windowName(of device: DeviceID) -> String {
    devices.first { $0.id == device }.map(displayName(of:)) ?? ""
  }

  /// The same name, unescaped, for a file name (which `CaptureFiles.baseName` makes safe).
  func fileName(of device: DeviceID) -> String {
    let suffixes = DeviceNames.suffixes(for: devices.map { ($0.id, $0.info.name) })
    guard let info = devices.first(where: { $0.id == device })?.info else { return "" }
    return DeviceNames.named(info.name, suffix: suffixes[device])
  }

  /// Open in Terminal: asks the agent for the `adb` it found and the serial of the route it
  /// serves the device by, writes a script that runs `adb -s <serial> shell` (see `ShellLaunch`),
  /// and opens it in Terminal.
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
