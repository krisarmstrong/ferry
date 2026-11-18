import DeviceKit
import Foundation

/// A package's folder tree as one stream, so it can cross between the agent and the extension
/// through a single file descriptor, as a file's bytes do.
///
/// The format is Ferry's own and minimal: a magic line, then one record per folder or regular
/// file (kind, relative path, and for a file its size and bytes), then an end record. Links and
/// anything else are left out. Reading trusts nothing: every path must be relative, made of
/// ordinary names, and is created only under the destination, which must be new.
public enum PackageArchive {
  private static let magic = Data("FERRYPKG1\n".utf8)
  private static let chunk = 1 << 20
  private static let maxPathBytes = 4096
  private static let maxEntries = 100_000

  private enum Kind: UInt8 {
    case end = 0
    case folder = 1
    case file = 2
  }

  /// Writes the folders and regular files under `root`, depth first in name order, into
  /// `handle` from its current offset.
  public static func write(
    tree root: URL, to handle: FileHandle, budget: TreeBudget = .standard
  ) throws(TransportError) {
    var usage = TreeBudget.Usage(budget)
    do {
      try handle.write(contentsOf: magic)
      try writeEntries(of: root, prefix: "", depth: 1, usage: &usage, to: handle)
      try handle.write(contentsOf: Data([Kind.end.rawValue]))
    } catch let error as TransportError {
      throw error
    } catch {
      throw .io("writing package failed: \(error.localizedDescription)")
    }
  }

  /// Reads an archive from `handle`, from its current offset, into a new folder at
  /// `destination`.
  /// A tree past `budget` is `.packageTooLarge`. Whatever fails, nothing is left at
  /// `destination`.
  ///
  /// With `quarantine`, the folder and every folder and file in it get that value as
  /// `com.apple.quarantine`, so contents from a device are checked by Gatekeeper; one that cannot
  /// be marked fails the extraction.
  public static func extract(
    from handle: FileHandle, to destination: URL, budget: TreeBudget = .standard,
    quarantine: Data? = nil
  ) throws(TransportError) {
    do throws(TransportError) {
      try extractEntries(from: handle, to: destination, budget: budget, quarantine: quarantine)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  private static func extractEntries(
    from handle: FileHandle, to destination: URL, budget: TreeBudget, quarantine: Data?
  ) throws(TransportError) {
    var usage = TreeBudget.Usage(budget)
    do {
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
      try mark(destination, quarantine)
      guard try handle.read(upToCount: magic.count) == magic else { throw bad("not a package") }
      for _ in 0..<maxEntries {
        guard let kind = Kind(rawValue: try byte(handle)) else { throw bad("unknown record") }
        if kind == .end { return }
        let (target, depth) = try validatedTarget(try path(handle), under: destination)
        switch kind {
        case .folder:
          try usage.add(depth: depth)
          try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
          try mark(target, quarantine)
        case .file:
          let size = try integer(handle, bytes: 8)
          try usage.add(depth: depth, size: size)
          try copyFile(from: handle, size: size, to: target)
          try mark(target, quarantine)
        case .end:
          return
        }
      }
      throw bad("too many entries")
    } catch let error as TransportError {
      throw error
    } catch {
      throw .io("reading package failed: \(error.localizedDescription)")
    }
  }

  // MARK: Writing

  private static func writeEntries(
    of folder: URL, prefix: String, depth: Int, usage: inout TreeBudget.Usage,
    to handle: FileHandle
  ) throws {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    let children = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: keys
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    for child in children {
      let values = try child.resourceValues(forKeys: Set(keys))
      guard values.isSymbolicLink != true else { continue }
      let path = prefix + child.lastPathComponent
      if values.isDirectory == true {
        try usage.add(depth: depth)
        try record(.folder, path, to: handle)
        try writeEntries(
          of: child, prefix: path + "/", depth: depth + 1, usage: &usage, to: handle)
      } else if values.isRegularFile == true {
        try usage.add(depth: depth, size: try LocalFile.regularFileSize(child))
        try record(.file, path, to: handle)
        try writeFile(child, to: handle)
      }
    }
  }

  private static func record(_ kind: Kind, _ path: String, to handle: FileHandle) throws {
    let bytes = Data(path.utf8)
    var data = Data([kind.rawValue])
    withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
    data.append(bytes)
    try handle.write(contentsOf: data)
  }

  private static func writeFile(_ url: URL, to handle: FileHandle) throws {
    let source = try FileHandle(forReadingFrom: url)
    defer { try? source.close() }
    let size = try LocalFile.regularFileSize(url)
    var data = Data()
    withUnsafeBytes(of: size.bigEndian) { data.append(contentsOf: $0) }
    try handle.write(contentsOf: data)
    var remaining = size
    while remaining > 0 {
      guard let block = try source.read(upToCount: Int(min(UInt64(chunk), remaining))),
        !block.isEmpty
      else { throw bad("file changed while archived") }
      try handle.write(contentsOf: block)
      remaining -= UInt64(block.count)
    }
  }

  // MARK: Reading

  private static func byte(_ handle: FileHandle) throws -> UInt8 {
    guard let data = try handle.read(upToCount: 1), let value = data.first else {
      throw bad("truncated")
    }
    return value
  }

  private static func integer(_ handle: FileHandle, bytes: Int) throws -> UInt64 {
    guard let data = try handle.read(upToCount: bytes), data.count == bytes else {
      throw bad("truncated")
    }
    return data.reduce(0) { $0 << 8 | UInt64($1) }
  }

  private static func path(_ handle: FileHandle) throws -> String {
    let length = Int(try integer(handle, bytes: 4))
    guard (1...maxPathBytes).contains(length), let data = try handle.read(upToCount: length),
      data.count == length, let path = String(data: data, encoding: .utf8)
    else { throw bad("bad path") }
    return path
  }

  /// `path` under `destination`, if it is relative and made of ordinary names only, and how
  /// many names deep it is.
  private static func validatedTarget(_ path: String, under destination: URL) throws -> (
    URL, Int
  ) {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    var target = destination
    for component in components {
      let name = String(component)
      guard !name.isEmpty, name != ".", name != "..", !name.contains("\0"),
        name.utf8.count <= 255
      else { throw bad("bad path") }
      target = target.appending(path: name)
    }
    return (target, components.count)
  }

  private static func copyFile(from handle: FileHandle, size: UInt64, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw bad("cannot create \(url.lastPathComponent)") }
    let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? output.close() }
    var remaining = size
    while remaining > 0 {
      guard let block = try handle.read(upToCount: Int(min(UInt64(chunk), remaining))),
        !block.isEmpty
      else { throw bad("truncated") }
      try output.write(contentsOf: block)
      remaining -= UInt64(block.count)
    }
  }

  /// Sets `quarantine` as `com.apple.quarantine` on `url`, which extraction just made.
  private static func mark(_ url: URL, _ quarantine: Data?) throws {
    guard let quarantine else { return }
    let result = quarantine.withUnsafeBytes { bytes in
      setxattr(url.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
    }
    guard result == 0 else { throw bad("cannot mark \(url.lastPathComponent) as downloaded") }
  }

  private static func bad(_ reason: String) -> TransportError {
    .io("bad package archive: \(reason)")
  }
}
