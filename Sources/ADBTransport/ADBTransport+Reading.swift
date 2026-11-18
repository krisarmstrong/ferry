import DeviceKit
import Foundation

/// What a scan reads from the server and the devices, each answer bounded in time.
extension ADBTransport {
  /// The device behind an adb serial, or `nil` if it reports no serial number.
  static func info(of serial: String, on host: ADBHost) async throws(ADBError)
    -> DeviceInfo?
  {
    let serialNumber = try await property("ro.serialno", of: serial, on: host)
    guard !serialNumber.isEmpty else { return nil }
    let manufacturer = try await property("ro.product.manufacturer", of: serial, on: host)
    let model = try await property("ro.product.model", of: serial, on: host)
    return DeviceInfo(
      id: DeviceID(serial: serialNumber),
      manufacturer: isPlatformVendor(manufacturer) ? "" : manufacturer,
      model: model.isEmpty ? "Android device" : model)
  }

  /// Chip and platform makers that boards built on a reference design report as their
  /// manufacturer (both NetAlly units say `freescale`), which names the SoC, not the device.
  static let platformVendors: Set<String> = [
    "", "unknown", "android", "freescale", "nxp", "qualcomm", "qcom", "mediatek", "mtk",
    "rockchip", "allwinner", "amlogic", "spreadtrum", "unisoc", "intel", "nvidia",
  ]

  static func isPlatformVendor(_ manufacturer: String) -> Bool {
    platformVendors.contains(manufacturer.lowercased())
  }

  /// `body`'s result, or a failure once `limit` has passed. `body` is cancelled then, which
  /// closes the connection it waits on.
  static func within<T: Sendable>(
    _ limit: Duration, _ body: @escaping @Sendable () async throws(ADBError) -> T
  ) async throws(ADBError) -> T {
    let result = await withTaskGroup(of: Result<T, ADBError>?.self) { group in
      group.addTask {
        do throws(ADBError) {
          return .success(try await body())
        } catch {
          return .failure(error)
        }
      }
      group.addTask {
        guard (try? await Task.sleep(for: limit)) != nil else { return nil }
        return .failure(.failed("no answer within \(limit)"))
      }
      for await outcome in group {
        guard let outcome else { continue }
        group.cancelAll()
        return outcome
      }
      return .failure(.cancelled)
    }
    return try result.get()
  }

  static func property(_ name: String, of serial: String, on host: ADBHost)
    async throws(ADBError) -> String
  {
    let result = try await host.run(
      serial: serial, command: try ADBShell.command("getprop", [name]))
    guard result.status == 0 else {
      throw .failed("getprop \(name) exited with status \(result.status)")
    }
    return String(bytes: result.stdout, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// Names a device adb lists but will not serve, by its adb serial, as MTP names a device it
  /// cannot read by its USB location.
  static func describe(_ device: ADBDevice) -> DeviceInfo {
    DeviceInfo(
      id: DeviceID(serial: device.serial), manufacturer: "Unknown",
      model: device.model.map { $0.replacing("_", with: " ") } ?? "Android device")
  }
}
