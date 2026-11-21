import DeviceKit
import Foundation
import os

/// What a scan reads from the server and the devices, each answer bounded in time.
extension ADBTransport {
  /// The device behind an adb serial, or `nil` if it reports no serial number. A scan names the
  /// `transportID` it listed, so it reads exactly the unit it listed.
  static func info(of serial: String, on host: ADBHost, transportID: String? = nil)
    async throws(ADBError) -> DeviceInfo?
  {
    func read(_ name: String) async throws(ADBError) -> String {
      try await property(name, of: serial, on: host, transportID: transportID)
    }
    let serialNumber = try await read("ro.serialno")
    guard !serialNumber.isEmpty else { return nil }
    let manufacturer = try await read("ro.product.manufacturer")
    let model = try await read("ro.product.model")
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

  /// `body`'s result, or a failure once `limit` has passed on `clock`. `body` is cancelled then,
  /// which closes the connection it waits on.
  static func within<T: Sendable>(
    _ limit: Duration, on clock: any Clock<Duration> = ContinuousClock(),
    _ body: @escaping @Sendable () async throws(ADBError) -> T
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
        guard (try? await clock.sleep(for: limit)) != nil else { return nil }
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

  static func property(
    _ name: String, of serial: String, on host: ADBHost, transportID: String? = nil
  ) async throws(ADBError) -> String {
    let result = try await host.run(
      serial: serial, command: try ADBShell.command("getprop", [name]), transportID: transportID)
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

extension ADBTransport {
  /// One connection adb lists. A name is kept per connection, not per serial: adb reconnects a
  /// network address by itself, and the unit answering there may be another one (DHCP gave it
  /// the address) without the serial ever leaving the list between two scans.
  struct Listing: Hashable {
    let serial: String
    let transportID: String?

    init(_ device: ADBDevice) {
      serial = device.serial
      transportID = device.transportID
    }
  }

  /// Reads the devices behind `listings` from their properties, all at once, each bounded by
  /// `answerLimit`. One whose serial cannot be read in time is left out, uncached, and asked
  /// again next scan; a cancelled scan throws.
  static func read(
    _ listings: Set<Listing>, on host: ADBHost, within limit: Duration,
    clock: any Clock<Duration>
  ) async throws(TransportError) -> [Listing: DeviceInfo] {
    let results = await withTaskGroup(of: (Listing, Result<DeviceInfo?, ADBError>).self) { group in
      for listing in listings {
        group.addTask {
          do throws(ADBError) {
            return (
              listing,
              .success(
                try await Self.within(limit, on: clock) { () async throws(ADBError) in
                  try await Self.info(
                    of: listing.serial, on: host, transportID: listing.transportID)
                })
            )
          } catch {
            return (listing, .failure(error))
          }
        }
      }
      var results: [(Listing, Result<DeviceInfo?, ADBError>)] = []
      for await result in group { results.append(result) }
      return results
    }
    if Task.isCancelled { throw .cancelled }
    var named: [Listing: DeviceInfo] = [:]
    for (listing, result) in results {
      let serial = listing.serial
      switch result {
      case .success(let info?):
        named[listing] = info
      case .success(nil):
        Self.log.info("\(serial, privacy: .private) reports no ro.serialno; leaving it out")
      case .failure(let error):
        Self.log.info(
          "reading \(serial, privacy: .private) failed: \(String(describing: error), privacy: .public)"
        )
      }
    }
    return named
  }
}
