import DeviceKit
import Foundation

/// Help's Copy Diagnostics: a plain-text report for the user to paste into a support message.
/// Nothing leaves the Mac unless they paste it. It holds what `LogPrivacyTests` lets the log
/// show in public (versions, states, counts, kinds of error) and nothing it keeps private: no
/// serial, network address, device file name or path in the home folder. A device is named by
/// the model it reports; its id may be its serial or its address.
extension AppModel {
  public func copyDiagnostics() {
    services.copy(diagnosticsReport())
  }

  /// In English, like the log: it is read by whoever answers the support message.
  func diagnosticsReport() -> String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info["CFBundleVersion"] as? String ?? "unknown"
    var lines = [
      "Ferry diagnostics",
      "Ferry: \(version) (\(build))",
      "Helper: \(helperLine)",
      "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
      "adb: \(adbLine)",
    ]
    lines.append(devices.isEmpty ? "Devices: none" : "Devices: \(devices.count)")
    for device in devices {
      lines.append(
        "- \(DisplayText.sanitized(device.info.model)) · \(device.method.rawValue) · "
          + Self.kind(of: device.state))
    }
    lines.append(recentErrors.isEmpty ? "Recent errors: none" : "Recent errors, oldest first:")
    lines += recentErrors.map { "- \($0)" }
    return lines.joined(separator: "\n") + "\n"
  }

  private var helperLine: String {
    let state =
      switch agent {
      case .checking: "checking"
      case .running: "running"
      case .unreachable: "not responding (\(helper))"
      case .replaced: "replaced by an update"
      }
    // The code directory hash of the helper in the bundle: which build it is, nothing more.
    return services.agentBuild().map { "\(state), build \($0.prefix(12))" } ?? state
  }

  private var adbLine: String {
    let server =
      switch adbStatus {
      case nil: "not checked yet"
      case .available?: "installed, server running"
      case .serverDown?: "installed, server not running"
      case .notInstalled?: "not installed"
      }
    return services.fetchedPlatformToolsVersion().map { "\(server); Ferry's adb \($0)" } ?? server
  }

  /// A state's case, and a failure's kind, without the values they carry (paths, names).
  private static func kind(of state: DeviceState) -> String {
    switch state {
    case .ready: "ready"
    case .notSharingFiles: "notSharingFiles"
    case .ejected: "ejected"
    case .busy: "busy"
    case .failed(let error): "failed (\(caseName(error)))"
    }
  }

  private static func caseName(_ error: TransportError) -> String {
    Mirror(reflecting: error).children.first?.label ?? String(describing: error)
  }
}
