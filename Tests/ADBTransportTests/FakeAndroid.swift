import Foundation
import os

@testable import ADBTransport

/// An Android 8 device behind `FakeADBServer`: an in-memory filesystem served over the sync
/// service and a toybox-like shell (see `FakeAndroid+Server.swift`, `FakeAndroid+Shell.swift`).
///
/// Paths are byte strings, as on the device: two names are one only if their bytes are, so an
/// NFD name and its NFC form are different files. Under `/storage/emulated` (and any root passed
/// as `caseInsensitive`) a lookup ignores ASCII case, as sdcardfs does, while names keep the case
/// they were created with.
final class FakeAndroid: Sendable {
  typealias Path = [UInt8]

  enum Node: Equatable {
    case folder(mtime: Int64)
    case file(Data, mtime: Int64)
    /// Anything else on disk (a symlink, a socket): listed, but not a file or a folder.
    case special
  }

  /// A failure the next matching shell command reports instead of running.
  struct ShellFailure {
    let program: String
    let status: Int32
    let stderr: String
  }

  /// A mounted filesystem as `df -k` reports it, in 1K blocks.
  struct Mount {
    let mountPoint: Path
    let filesystem: String
    let total: UInt64
    let used: UInt64
  }

  struct State {
    var nodes: [Path: Node] = [:]
    var caseInsensitive: [Path] = []
    /// Roots whose lookups also ignore trailing dots, as Linux vfat does.
    var trailingDotsIgnored: [Path] = []
    var mounts: [Mount] = []
    var features = "cmd,shell_v2,stat_v2"
    var gone = false
    var commands: [[String]] = []
    var syncRequests: [(id: String, path: String)] = []
    var shellFailures: [ShellFailure] = []
    var beforeShell: [(program: String, action: @Sendable (FakeAndroid) -> Void)] = []
    var beforeSync: [(id: String, action: @Sendable (FakeAndroid) -> Void)] = []
    /// Bytes of DATA a SEND or RECV carries before the device drops off.
    var dropAfterBytes: (id: String, bytes: Int)?
    var sendFailure: String?
    /// Programs the shell starts but never answers for, as on a wedged device.
    var hangingPrograms: Set<String> = []
    /// What `getprop <name>` prints.
    var properties: [String: String] = [:]
    /// What `ip -4 addr` prints.
    var addresses = ""
    var peers: [ADBStream] = []
    /// `sync:` connections the client has not yet closed.
    var openSyncs = 0
    var clock: Int64 = 1_700_000_000
    var tools = Tools()
  }

  let state = OSAllocatedUnfairLock(initialState: State())
  static let internalRoot = "/storage/emulated/0"

  /// A device with internal shared storage mounted, holding nothing. With `vfat`, lookups on
  /// the volumes also ignore trailing dots, as Linux's vfat driver does.
  init(volumes: [String] = [], vfat: Bool = false) {
    state.withLock { state in
      for folder in ["/storage", "/storage/emulated", Self.internalRoot, "/storage/self"] {
        state.nodes[Self.bytes(folder)] = .folder(mtime: 1_600_000_000)
      }
      state.caseInsensitive = [Self.bytes("/storage/emulated")]
      state.mounts = [
        Mount(
          mountPoint: Self.bytes("/storage/emulated"), filesystem: "/data/media", total: 23_260_324,
          used: 272_504)
      ]
      for volume in volumes {
        let root = "/storage/" + volume
        state.nodes[Self.bytes(root)] = .folder(mtime: 1_600_000_000)
        state.caseInsensitive.append(Self.bytes(root))
        if vfat { state.trailingDotsIgnored.append(Self.bytes(root)) }
        state.mounts.append(
          Mount(
            mountPoint: Self.bytes(root), filesystem: "/dev/fuse", total: 62_522_624,
            used: 1_048_576))
      }
    }
  }

  static func bytes(_ path: String) -> Path { Array(path.utf8) }

  /// `bytes` as text, or as its byte values when it is not UTF-8.
  static func text(_ bytes: some Collection<UInt8>) -> String {
    String(bytes: bytes, encoding: .utf8) ?? Array(bytes).description
  }

  /// `relative` under internal storage, as bytes.
  static func internalPath(_ relative: String) -> Path { bytes(internalRoot + relative) }

  // MARK: Test setup and inspection

  func addFolder(_ relative: String, mtime: Int64 = 1_650_000_000) {
    state.withLock { $0.nodes[Self.internalPath(relative)] = .folder(mtime: mtime) }
  }

  func addFile(_ relative: String, _ contents: Data, mtime: Int64 = 1_650_000_000) {
    state.withLock { $0.nodes[Self.internalPath(relative)] = .file(contents, mtime: mtime) }
  }

  /// A name under internal storage given as raw bytes, which need not be UTF-8.
  func addRaw(_ folder: String, name: [UInt8], node: Node) {
    let path = Self.internalPath(folder == "/" ? "" : folder) + [UInt8(ascii: "/")] + name
    state.withLock { $0.nodes[path] = node }
  }

  /// The raw names in a folder under internal storage, sorted by their bytes.
  func rawNames(in folder: String) -> [[UInt8]] {
    let parent = Self.internalPath(folder == "/" ? "" : folder)
    return state.withLock { $0.children(of: parent).map(Self.name) }
      .sorted { $0.lexicographicallyPrecedes($1) }
  }

  func removeMount(_ root: String) {
    state.withLock { state in
      let prefix = Self.bytes(root)
      state.nodes = state.nodes.filter { !Self.isSame($0.key, orInside: prefix) }
    }
  }

  func node(_ relative: String) -> Node? {
    state.withLock { $0.nodes[Self.internalPath(relative)] }
  }

  func contents(_ relative: String) -> Data? {
    guard case .file(let data, _) = node(relative) else { return nil }
    return data
  }

  /// Every path under internal storage, relative to it, sorted.
  var tree: [String] {
    state.withLock { state in
      let root = Self.bytes(Self.internalRoot)
      return state.nodes.keys.filter { $0.count > root.count && Self.isSame($0, orInside: root) }
        .map { Self.text($0.dropFirst(root.count)) }.sorted()
    }
  }

  var commands: [[String]] { state.withLock { $0.commands } }
  /// The commands that change something: all but `df`, which reading storages runs.
  var changes: [[String]] { commands.filter { $0.first != "df" } }
  var syncRequests: [(id: String, path: String)] { state.withLock { $0.syncRequests } }
  var openSyncs: Int { state.withLock { $0.openSyncs } }

  func failNextShell(_ program: String, status: Int32 = 1, stderr: String) {
    state.withLock {
      $0.shellFailures.append(ShellFailure(program: program, status: status, stderr: stderr))
    }
  }

  /// Runs `action` just before the next `program` command, as another app on the phone would.
  func beforeNextShell(_ program: String, _ action: @escaping @Sendable (FakeAndroid) -> Void) {
    state.withLock { $0.beforeShell.append((program, action)) }
  }

  /// Runs `action` just before the device handles the next sync request `id` (`RECV`, `SEND`).
  func beforeNextSync(_ id: String, _ action: @escaping @Sendable (FakeAndroid) -> Void) {
    state.withLock { $0.beforeSync.append((id, action)) }
  }

  func failNextSend(_ message: String) {
    state.withLock { $0.sendFailure = message }
  }

  /// The device drops off once a transfer (`SEND` or `RECV`) has carried `bytes`.
  func dropDuring(_ id: String, afterBytes bytes: Int) {
    state.withLock { $0.dropAfterBytes = (id, bytes) }
  }

  /// Every open connection to the device closes, while the device stays attached.
  func dropConnections() {
    let peers = state.withLock { state in
      defer { state.peers = [] }
      return state.peers
    }
    for peer in peers { peer.cancel() }
  }

  /// The device leaves: the server forgets it and every open connection to it closes.
  func unplug() {
    state.withLock { $0.gone = true }
    dropConnections()
  }

  // MARK: Filesystem

  static func isSame(_ path: Path, orInside ancestor: Path) -> Bool {
    path == ancestor || (path.starts(with: ancestor) && path[ancestor.count] == UInt8(ascii: "/"))
  }

  static func parent(_ path: Path) -> Path {
    guard let slash = path.lastIndex(of: UInt8(ascii: "/")), slash > 0 else {
      return [UInt8(ascii: "/")]
    }
    return Array(path[..<slash])
  }

  static func name(_ path: Path) -> Path {
    guard let slash = path.lastIndex(of: UInt8(ascii: "/")) else { return path }
    return Array(path[(slash + 1)...])
  }

  static func folded(_ bytes: Path) -> Path {
    bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
  }
}

extension FakeAndroid.State {
  typealias Path = FakeAndroid.Path

  mutating func tick() -> Int64 {
    clock += 1
    return clock
  }

  func children(of folder: Path) -> [Path] {
    nodes.keys.filter { $0.count > folder.count && FakeAndroid.parent($0) == folder }
  }

  /// The stored path `path` names: exact bytes, or under a case-insensitive root a name equal
  /// but for ASCII case, component by component.
  func resolve(_ path: Path) -> Path? {
    if nodes[path] != nil { return path }
    guard path.first == UInt8(ascii: "/") else { return nil }
    var current: Path = []
    for component in path.split(separator: UInt8(ascii: "/")) {
      let exact = current + [UInt8(ascii: "/")] + component
      if nodes[exact] != nil {
        current = exact
        continue
      }
      guard caseInsensitive.contains(where: { FakeAndroid.isSame(exact, orInside: $0) }) else {
        return nil
      }
      let undotted = trailingDotsIgnored.contains { FakeAndroid.isSame(exact, orInside: $0) }
      let fold = { (name: Path) -> Path in
        var name = FakeAndroid.folded(name)
        while undotted, name.count > 1, name.last == UInt8(ascii: ".") { name.removeLast() }
        return name
      }
      let key = fold(Array(component))
      guard
        let match = children(of: current.isEmpty ? [UInt8(ascii: "/")] : current).first(where: {
          fold(FakeAndroid.name($0)) == key
        })
      else { return nil }
      current = match
    }
    return current
  }

  func node(at path: Path) -> Node? { resolve(path).flatMap { nodes[$0] } }

  typealias Node = FakeAndroid.Node

  /// Moves `source` and everything in it to `destination`.
  mutating func relocate(_ source: Path, to destination: Path) {
    for key in nodes.keys where FakeAndroid.isSame(key, orInside: source) {
      nodes[destination + key.dropFirst(source.count)] = nodes.removeValue(forKey: key)
    }
  }

  /// Where a `SEND` of `requested` writes, as adbd opens it: an existing file there goes first,
  /// missing folders are made, and an existing folder refuses it (`nil`).
  mutating func create(_ requested: Path) -> Path? {
    if let existing = resolve(requested) {
      if case .folder = nodes[existing] { return nil }
      nodes[existing] = nil
    }
    var folder: Path = []
    for component in FakeAndroid.parent(requested).split(separator: UInt8(ascii: "/")) {
      let next = folder + [UInt8(ascii: "/")] + component
      folder = resolve(next) ?? next
      if nodes[folder] == nil { nodes[folder] = .folder(mtime: tick()) }
    }
    let path = folder + [UInt8(ascii: "/")] + FakeAndroid.name(requested)
    nodes[path] = .file(Data(), mtime: tick())
    return path
  }

  mutating func remove(_ path: Path) {
    nodes = nodes.filter { !FakeAndroid.isSame($0.key, orInside: path) }
  }
}
