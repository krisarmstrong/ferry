import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

/// What the controller does when a device's method or storage keys change.
extension DomainController {
  /// Records each ready device's method and returns the devices whose method changed.
  func noteMethods(of devices: [AttachedDevice]) -> [DeviceID] {
    var moved: [DeviceID] = []
    for device in devices {
      guard case .ready = device.state else { continue }
      if let last = lastMethods[device.id], last != device.method { moved.append(device.id) }
      lastMethods[device.id] = device.method
    }
    return moved
  }

  /// Removes the domain a storage of an attached device had under a former key, keeping unsent
  /// changes as Remove Ferry does, unless it is one of the `live` domains. Where they went is
  /// kept for the app. The controller lets go of the domain first, as an eject does; a removal
  /// the system refuses leaves the domain with the system, and the next start adopts it and
  /// retires it again.
  func retire(_ former: StorageID, live: Set<String>) async {
    let identifier = DomainNaming.identifier(for: former)
    guard domains[identifier] != nil, !live.contains(identifier) else { return }
    domains[identifier] = nil
    await discardTable(of: identifier)
    do {
      let preserved = try await manager.remove(identifier)
      if let preserved { preservedByRetirement.append(preserved) }
      log.info("retired domain \(identifier, privacy: .private)")
    } catch {
      log.error(
        "retiring domain \(identifier, privacy: .private) failed: \(error, privacy: .private)")
      log.error("the next start adopts \(identifier, privacy: .private) and retires it again")
    }
  }

  /// After a method change, lists the device's known folders again and signals each domain, so
  /// FileProvider holds the new method's versions of files before it saves over them.
  func resync(_ device: DeviceID) async {
    for identifier in connectedDomains(of: device) {
      _ = await relistKnownFolders(of: identifier)
      await signal(identifier)
    }
  }
}
