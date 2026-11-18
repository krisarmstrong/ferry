import DeviceKit
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "WirelessADB")

/// The file remembered devices are kept in: serial → name, method and addresses. Addresses are
/// read back through `WirelessEndpoint` validation, so one that is not an address never reaches
/// adb; an unreadable file is an empty list.
enum WirelessStore {
  private struct Stored: Codable {
    var devices: [String: Device]
  }

  private struct Device: Codable {
    var name: String
    var method: WirelessADB.Method
    var addresses: [String]
  }

  static func load(_ file: URL) -> [DeviceID: WirelessADB.Entry] {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return [:]
    } catch {
      log.error("reading remembered devices failed: \(error, privacy: .private)")
      return [:]
    }
    guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
      log.error("remembered devices are unreadable, starting empty")
      return [:]
    }
    var entries: [DeviceID: WirelessADB.Entry] = [:]
    for (serial, device) in stored.devices where !serial.isEmpty {
      let addresses = device.addresses.compactMap {
        WirelessEndpoint(parsing: $0, defaultPort: nil)
      }
      if addresses.count != device.addresses.count {
        log.error("dropped stored addresses that are not addresses")
      }
      entries[DeviceID(serial: serial)] = WirelessADB.Entry(
        name: device.name, method: device.method, addresses: addresses)
    }
    return entries
  }

  static func save(_ entries: [DeviceID: WirelessADB.Entry], to file: URL) {
    let stored = Stored(
      devices: Dictionary(
        uniqueKeysWithValues: entries.map {
          (
            $0.key.serial,
            Device(
              name: $0.value.name, method: $0.value.method,
              addresses: $0.value.addresses.map(\.argument))
          )
        }))
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(stored).write(to: file, options: .atomic)
    } catch {
      log.error("saving remembered devices failed: \(error, privacy: .private)")
    }
  }
}
