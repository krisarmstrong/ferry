/// What tells apart devices that go by the same name (`DeviceInfo.name`): the end of each one's
/// serial, as in `LinkRunner 10G (AAAA)`. The Ferry menu, the Finder locations and the Finder
/// Sync menu all name devices through this, so one device has one name everywhere.
public enum DeviceNames {
  /// The serial ending each device needs, keyed by device: none for a device whose name no
  /// other listed device has. Within a group of one name, every device gets the last four
  /// characters of its serial, or more, the same count for all, until no two are equal (at most
  /// the whole serial, which is unique).
  public static func suffixes(for devices: [(id: DeviceID, name: String)]) -> [DeviceID: String] {
    var groups: [String: Set<DeviceID>] = [:]
    for device in devices {
      groups[device.name, default: []].insert(device.id)
    }
    var suffixes: [DeviceID: String] = [:]
    for ids in groups.values where ids.count > 1 {
      let longest = ids.map(\.serial.count).max() ?? 0
      var length = 4
      while length < longest, Set(ids.map { $0.serial.suffix(length) }).count < ids.count {
        length += 1
      }
      for id in ids {
        suffixes[id] = String(id.serial.suffix(length))
      }
    }
    return suffixes
  }

  /// `name` with `suffix` in brackets, if there is one.
  public static func named(_ name: String, suffix: String?) -> String {
    suffix.map { "\(name) (\($0))" } ?? name
  }
}
