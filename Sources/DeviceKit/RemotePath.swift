import Foundation

public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
  public static let root = RemotePath(components: [])

  /// How many folders below a tree's top Ferry walks on the device (deleting a folder with its
  /// contents): a deeper tree is refused rather than walked, so a device that reports a loop
  /// cannot exhaust the stack or run forever.
  public static let maxTreeDepth = 64

  /// Whether a device can store `name`. libmtp sends a name as at most 255 bytes of UTF-8 (it
  /// cuts a longer one), and PTP carries at most 254 UTF-16 units (`ptp_pack_string` sends an
  /// empty name for more).
  public static func fitsOnDevice(_ name: String) -> Bool {
    name.utf8.count <= 255 && name.utf16.count <= 254
  }

  /// NFC-normalized path components; empty for the root.
  public let components: [String]

  private init(components: [String]) {
    self.components = components
  }

  /// Parses an absolute path such as `/DCIM/Camera`. `""` and `"/"` are the root.
  public init(_ string: String) throws(TransportError) {
    if string.isEmpty || string == "/" {
      self = .root
      return
    }
    guard string.hasPrefix("/") else { throw .invalidName(string) }
    var validated: [String] = []
    for name in string.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
      validated.append(try Self.validated(String(name)))
    }
    self.init(components: validated)
  }

  public func appending(_ name: String) throws(TransportError) -> RemotePath {
    RemotePath(components: components + [try Self.validated(name)])
  }

  public var parent: RemotePath? {
    components.isEmpty ? nil : RemotePath(components: Array(components.dropLast()))
  }

  public var name: String? { components.last }

  /// Whether this path is `ancestor` or inside it.
  public func isWithin(_ ancestor: RemotePath) -> Bool {
    components.starts(with: ancestor.components)
  }

  /// This path with `ancestor` replaced by `replacement`, as after `ancestor` moved there; `nil`
  /// unless `isWithin(ancestor)`.
  public func rebased(from ancestor: RemotePath, to replacement: RemotePath) -> RemotePath? {
    guard isWithin(ancestor) else { return nil }
    return RemotePath(
      components: replacement.components + components.dropFirst(ancestor.components.count))
  }

  /// The form two names share when Android storage treats them as one name: NFC and without
  /// case, as FAT and exFAT cards and emulated internal storage compare them.
  public static func collisionKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
      .precomposedStringWithCanonicalMapping
  }

  public var description: String {
    components.isEmpty ? "/" : "/" + components.joined(separator: "/")
  }

  public init(from decoder: any Decoder) throws {
    let string = try decoder.singleValueContainer().decode(String.self)
    do {
      try self.init(string)
    } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "invalid remote path: \(string)"))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  private static func validated(_ name: String) throws(TransportError) -> String {
    let normalized = name.precomposedStringWithCanonicalMapping
    guard !normalized.isEmpty, normalized != ".", normalized != "..",
      !normalized.contains("/"), !normalized.contains("\0")
    else { throw .invalidName(name) }
    return normalized
  }
}
