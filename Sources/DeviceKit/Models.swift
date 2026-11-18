import Foundation

public struct DeviceInfo: Hashable, Sendable, Codable {
  public let id: DeviceID
  public let manufacturer: String
  public let model: String

  public init(id: DeviceID, manufacturer: String, model: String) {
    self.id = id
    self.manufacturer = manufacturer
    self.model = model
  }
}

public struct StorageInfo: Hashable, Sendable, Codable {
  public let id: StorageID
  public let description: String
  public let capacity: UInt64
  public let free: UInt64
  /// The device says the storage is FAT-based, so no file over 4 GB fits. MTP says so only for
  /// a camera-style DCF filesystem; an Android SD card reports a generic one even when it is
  /// FAT32, so this is often `false` where the limit applies.
  public let isFATLike: Bool

  public init(
    id: StorageID, description: String, capacity: UInt64, free: UInt64, isFATLike: Bool = false
  ) {
    self.id = id
    self.description = description
    self.capacity = capacity
    self.free = free
    self.isFATLike = isFATLike
  }
}

public enum ItemKind: Sendable, Codable {
  case file
  case folder
}

public struct RemoteItem: Hashable, Sendable, Codable {
  public let path: RemotePath
  public let kind: ItemKind
  public let size: UInt64
  public let modified: Date

  public init(path: RemotePath, kind: ItemKind, size: UInt64, modified: Date) {
    self.path = path
    self.kind = kind
    self.size = size
    self.modified = modified
  }
}

public struct DeviceCapabilities: OptionSet, Sendable, Codable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let move = DeviceCapabilities(rawValue: 1 << 0)
  public static let copy = DeviceCapabilities(rawValue: 1 << 1)
  public static let partialRead = DeviceCapabilities(rawValue: 1 << 2)
}
