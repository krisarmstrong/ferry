import DeviceKit
import Foundation

/// What Device Info reads, all of it read-only: `getprop`, `dumpsys battery`, `ip -4 addr` and
/// `df`. A part the device cannot answer is left out; the rest is still shown.
enum ADBDeviceInfo {
  /// The battery's level, as a percent of its scale, and its state, from `dumpsys battery`.
  /// `nil` unless both are there.
  static func battery(fromDumpsys text: String) -> AndroidDeviceInfo.Battery? {
    var values: [String: Int] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let name = parts[0].trimmingCharacters(in: .whitespaces)
      guard ["level", "scale", "status"].contains(name), values[name] == nil else { continue }
      values[name] = Int(parts[1].trimmingCharacters(in: .whitespaces))
    }
    guard let level = values["level"], let status = values["status"], level >= 0 else {
      return nil
    }
    let scale = values["scale"].flatMap { $0 > 0 ? $0 : nil } ?? 100
    // The device prints these numbers: bound the level to its scale and multiply at full width,
    // so no value can overflow. The quotient is then at most 100.
    let product = min(level, scale).multipliedFullWidth(by: 100)
    let percent = scale.dividingFullWidth((high: product.high, low: product.low)).quotient
    return AndroidDeviceInfo.Battery(level: percent, state: state(ofStatus: status))
  }

  /// `BatteryManager`'s `BATTERY_STATUS_*` constants.
  private static func state(ofStatus status: Int) -> AndroidDeviceInfo.BatteryState {
    switch status {
    case 2: .charging
    case 3: .discharging
    case 4: .notCharging
    case 5: .full
    default: .unknown
    }
  }
}

extension ADBDeviceTools {
  /// The device's model, Android version, build, battery, addresses and internal storage. The
  /// device not answering at all throws; one command that fails only leaves its part empty.
  public func deviceInfo(route: ADBRoute) async throws(ADBError) -> AndroidDeviceInfo {
    let model = try await property("ro.product.model", route)
    let version = try await property("ro.build.version.release", route)
    let build = try await property("ro.build.display.id", route)
    let number = try await property("ro.serialno", route)
    let battery = try await output("dumpsys", ["battery"], route).flatMap {
      ADBDeviceInfo.battery(fromDumpsys: $0)
    }
    let addresses = try await output("ip", ["-4", "addr"], route).map {
      ADBWireless.networkAddresses(fromIPAddr: $0)
    }
    let space = try await output("df", ["-k", "--", ADBStorages.internalRoot], route).flatMap {
      ADBStorages.space(fromDF: $0)
    }
    return AndroidDeviceInfo(
      model: model, androidVersion: version, build: build,
      serial: number.isEmpty ? route.serial : number, battery: battery, addresses: addresses ?? [],
      storage: space.map {
        AndroidDeviceInfo.Storage(used: $0.capacity - min($0.free, $0.capacity), free: $0.free)
      })
  }

  private func property(_ name: String, _ route: ADBRoute) async throws(ADBError) -> String {
    try await output("getprop", [name], route)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
  }

  /// What `program` printed, or `nil` if it exited with a failure.
  private func output(_ program: String, _ arguments: [String], _ route: ADBRoute)
    async throws(ADBError) -> String?
  {
    let command = try ADBShell.command(program, arguments)
    let (host, limit) = (host, answerLimit)
    let result = try await ADBTransport.within(limit) { () async throws(ADBError) in
      try await host.run(route: route, command: command)
    }
    guard result.status == 0 else { return nil }
    return String(bytes: result.stdout, encoding: .utf8) ?? ""
  }
}
