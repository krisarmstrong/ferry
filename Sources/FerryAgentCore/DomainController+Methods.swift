import DeviceKit

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

  /// After a method change, lists the device's known folders again and signals each domain, so
  /// FileProvider holds the new method's versions of files before it saves over them.
  func resync(_ device: DeviceID) async {
    for identifier in connectedDomains(of: device) {
      _ = await relistKnownFolders(of: identifier)
      await signal(identifier)
    }
  }
}
