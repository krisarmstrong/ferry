import DeviceKit

/// What the controller does when a device's method or storage keys change.
extension DomainController {
  /// Records each ready device's method and storages, learns which volume a card MTP knows by
  /// description is when a device was just seen the other way in the same attachment, and
  /// returns the devices whose method changed and the volumes whose match moved to another card.
  func noteMethods(of devices: [AttachedDevice]) -> (moved: [DeviceID], unmatched: [StorageID]) {
    var moved: [DeviceID] = []
    var unmatched: [StorageID] = []
    for device in devices {
      guard case .ready(let storages) = device.state else { continue }
      if let last = lastReady[device.id], last.method != device.method {
        moved.append(device.id)
        if let replaced = learn(device.id, [last, (method: device.method, storages: storages)]) {
          unmatched.append(StorageID(device: device.id, key: replaced))
        }
      }
      lastReady[device.id] = (device.method, storages)
    }
    return (moved, unmatched)
  }

  /// Forgets the device's last reading, when it leaves or is newly attached: a later reading is
  /// of another attachment, whose cards may not be the ones seen.
  func forgetReading(of device: DeviceID) {
    lastReady[device] = nil
  }

  /// Learns which volume a card MTP knows by description is, from the device seen both ways.
  /// Returns the volume a replaced match had.
  private func learn(
    _ device: DeviceID, _ sides: [(method: ConnectionMethod, storages: [StorageInfo])]
  ) -> String? {
    guard let mtp = sides.first(where: { $0.method == .usbFileTransfer }),
      let adb = sides.first(where: { $0.method != .usbFileTransfer })
    else { return nil }
    let learnt = aliases.learn(device, mtp: mtp.storages, adb: adb.storages)
    if learnt.changed { aliases.save(to: itemStore) }
    return learnt.replaced
  }

  /// Removes the domain a storage of an attached device had under a former key, keeping unsent
  /// changes as Remove Ferry does, unless it is one of the `live` domains. Where they went is
  /// kept for the app.
  func retire(_ former: StorageID, live: Set<String>) async {
    let identifier = DomainNaming.identifier(for: former)
    guard domains[identifier] != nil, !live.contains(identifier) else { return }
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
