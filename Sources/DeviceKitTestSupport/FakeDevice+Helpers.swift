import DeviceKit
import Foundation

// MARK: Helpers

extension FakeDevice {
  static func isSame(_ path: RemotePath, orInside ancestor: RemotePath) -> Bool {
    path.components.starts(with: ancestor.components)
  }

  static func item(_ path: RemotePath, _ node: Node) -> RemoteItem {
    switch node {
    case .file(let data, let modified):
      RemoteItem(path: path, kind: .file, size: UInt64(data.count), modified: modified)
    case .folder(let modified):
      RemoteItem(path: path, kind: .folder, size: 0, modified: modified)
    }
  }

  /// Reads the whole file, or at most `limit` bytes when a limit is given.
  static func read(_ file: URL, upTo limit: UInt64?) throws(TransportError) -> Data {
    do {
      guard let limit else { return try Data(contentsOf: file) }
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      return try handle.read(upToCount: Int(clamping: limit)) ?? Data()
    } catch {
      throw .io(error.localizedDescription)
    }
  }
}

extension FakeDevice {
  /// As `DeviceSession.delete(_:in:expecting:)` checks what it deletes.
  func requireChecked(_ doomed: [RemotePath: Node], at path: RemotePath, _ expecting: [RemoteItem])
    throws(TransportError)
  {
    let checked = Dictionary(
      expecting.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    for (key, node) in doomed {
      let name = key.name ?? ""
      if key != path, SafeWriter.isPartial(name) || SafeWriter.isBackup(name) { continue }
      if let seen = checked[key], listedItem(key, node).matches(seen) { continue }
      throw key == path ? .changedOnDevice(path) : .directoryNotEmpty(path)
    }
  }
}
