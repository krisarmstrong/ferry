import Foundation

public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
  public static let root = RemotePath(components: [])

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
