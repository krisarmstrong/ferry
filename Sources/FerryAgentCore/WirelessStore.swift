import DeviceKit
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "WirelessADB")

/// The file remembered devices are kept in: serial → name, and each address with how it was
/// learnt. Addresses are read back through `WirelessEndpoint` validation, so one that is not an
/// address never reaches adb. A file that cannot be read is moved aside, as
/// `wireless.json.unreadable-<date>`, so the next save cannot overwrite the user's devices. A
/// remembered hostname (a `.local` name in particular) can be re-pointed by DNS or mDNS on the
/// LAN; as with an IP address taken over by another host, what guards it is that a reconnected
/// address must answer as the remembered device.
enum WirelessStore {
  private struct Stored: Codable {
    var devices: [String: Device]
  }

  private struct Device: Codable {
    var name: String
    var addresses: [StoredAddress]
  }

  private struct StoredAddress: Codable {
    var address: String
    var learnt: WirelessADB.Learnt
  }

  /// What a load found. `intact` is false when the file was there but could not be read: the
  /// devices it held are unknown.
  struct Loaded {
    var entries: [DeviceID: WirelessADB.Entry]
    var intact: Bool
  }

  static func load(_ file: URL, now: Date = Date()) -> Loaded {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return Loaded(entries: [:], intact: true)
    } catch {
      log.error("reading remembered devices failed: \(error, privacy: .private)")
      return Loaded(entries: [:], intact: moveAside(file, at: now))
    }
    guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
      log.error("remembered devices are unreadable")
      return Loaded(entries: [:], intact: moveAside(file, at: now))
    }
    var entries: [DeviceID: WirelessADB.Entry] = [:]
    for (serial, device) in stored.devices where !serial.isEmpty {
      let addresses = device.addresses.compactMap { stored in
        WirelessEndpoint(parsing: stored.address, defaultPort: nil).map {
          WirelessADB.Address(endpoint: $0, learnt: stored.learnt)
        }
      }
      if addresses.count != device.addresses.count {
        log.error("dropped stored addresses that are not addresses")
      }
      entries[DeviceID(serial: serial)] = WirelessADB.Entry(
        name: device.name, addresses: addresses)
    }
    return Loaded(entries: entries, intact: true)
  }

  /// Moves an unreadable store aside, beside it. Always false: the devices it held are unknown
  /// for this run, whether or not the move worked.
  private static func moveAside(_ file: URL, at now: Date) -> Bool {
    let aside = file.deletingLastPathComponent().appending(
      path: file.lastPathComponent + ".unreadable-" + stamp.string(from: now))
    do {
      try FileManager.default.moveItem(at: file, to: aside)
      log.error("moved the unreadable file aside as \(aside.lastPathComponent, privacy: .private)")
    } catch {
      log.error("moving the unreadable file aside failed: \(error, privacy: .private)")
    }
    return false
  }

  /// A fixed, sortable UTC stamp with no characters Finder shows differently.
  private static let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }()

  static func save(_ entries: [DeviceID: WirelessADB.Entry], to file: URL) {
    let stored = Stored(
      devices: Dictionary(
        uniqueKeysWithValues: entries.map {
          (
            $0.key.serial,
            Device(
              name: $0.value.name,
              addresses: $0.value.addresses.map {
                StoredAddress(address: $0.endpoint.argument, learnt: $0.learnt)
              })
          )
        }))
    do {
      try PrivateFile.write(try JSONEncoder().encode(stored), to: file)
    } catch {
      log.error("saving remembered devices failed: \(error, privacy: .private)")
    }
  }
}
