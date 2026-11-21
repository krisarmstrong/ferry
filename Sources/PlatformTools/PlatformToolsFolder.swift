import Foundation

/// Where Ferry keeps the `adb` it fetched: `~/Library/Application Support/Ferry/platform-tools`,
/// a folder per version holding `adb` and `NOTICE.txt`.
public struct PlatformToolsFolder: Sendable {
  public let root: URL

  public init(home: String) {
    root = URL(filePath: home, directoryHint: .isDirectory)
      .appending(
        path: "Library/Application Support/Ferry/platform-tools", directoryHint: .isDirectory)
  }

  public static var standard: PlatformToolsFolder { PlatformToolsFolder(home: NSHomeDirectory()) }

  public func adb(version: String) -> URL {
    root.appending(path: "\(version)/adb")
  }

  /// The fetched `adb` to use: `pinned`'s, or else the newest version fetched before, so a Ferry
  /// update that pins a new version leaves an offline Mac the adb it had.
  public func installedADB(pinned: String) -> URL? {
    installedADB(
      pinned: pinned,
      in: (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [],
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
  }

  func installedADB(
    pinned: String, in names: [String], isExecutable: (String) -> Bool
  ) -> URL? {
    let usable = names.compactMap(ReleaseVersion.init)
      .filter { isExecutable(adb(version: $0.text).path) }
    let chosen = usable.first { $0.text == pinned } ?? usable.max()
    return chosen.map { adb(version: $0.text) }
  }

  /// The version folders, by name; anything else (a staging folder) is not one.
  func versions() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
      .filter { ReleaseVersion($0) != nil }
  }
}

/// A version folder's name, `37.0.3`, ordered by its numbers.
struct ReleaseVersion: Comparable {
  let text: String
  private let numbers: [Int]

  init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(parts.count),
      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
    else { return nil }
    self.text = text
    numbers = parts.compactMap { Int($0) }
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.numbers.lexicographicallyPrecedes(rhs.numbers)
  }
}
