import DeviceKit

/// What the controller does when a device's method or storage keys change.
extension DomainController {
  /// Records each ready device's method and storages, learns which volume a card MTP knows by
  /// description is when a device was just seen the other way, and returns the devices whose
  /// method changed.
  func noteMethods(of devices: [AttachedDevice]) -> [DeviceID] {
    var moved: [DeviceID] = []
    for device in devices {
      guard case .ready(let storages) = device.state else { continue }
      if let last = lastReady[device.id], last.method != device.method {
        moved.append(device.id)
        learn(device.id, [last, (method: device.method, storages: storages)])
      }
      lastReady[device.id] = (device.method, storages)
    }
    return moved
  }

  /// Learns which volume a card MTP knows by description is, from the device seen both ways.
  private func learn(
    _ device: DeviceID, _ sides: [(method: ConnectionMethod, storages: [StorageInfo])]
  ) {
    guard let mtp = sides.first(where: { $0.method == .usbFileTransfer }),
      let adb = sides.first(where: { $0.method != .usbFileTransfer })
    else { return }
    if aliases.learn(device, mtp: mtp.storages, adb: adb.storages) {
      aliases.save(to: itemStore)
    }
  }

  /// Removes the domain a ready storage had under a former key, keeping unsent changes as Remove
  /// Ferry does, unless a live storage claims it. Where they went is kept for the app.
  func retire(_ former: StorageID) async {
    let identifier = DomainNaming.identifier(for: former)
    guard let domain = domains[identifier], [nil, former].contains(domain.storage) else { return }
    domains[identifier] = nil
    await discardTable(of: identifier)
    if let preserved = await remove(identifier) {
      preservedByRetirement.append(preserved)
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
