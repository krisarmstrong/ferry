import Foundation

@testable import ADBTransport

/// The adb server's view of a `FakeAndroid`: the host requests a session makes, the sync service
/// as adbd 8.1 runs it (`file_sync_service.cpp`), and `shell,v2` running the fake toybox.
extension FakeAndroid {
  typealias Peer = FakeADBServer.Peer

  /// Starts a server that routes every connection for `serial` to this device.
  func serve(serial: String = "S") async throws -> FakeADBServer {
    try await FakeADBServer.start { [self] peer in try await self.handle(peer, serial: serial) }
  }

  private func handle(_ peer: Peer, serial: String) async throws {
    try await handle(peer, serial: serial, first: try await peer.request())
  }

  /// Serves a connection for `serial` whose first request has already been read.
  func handle(_ peer: Peer, serial: String, first: String) async throws {
    let gone = state.withLock { $0.gone }
    if first == "host-serial:\(serial):features" {
      if gone {
        try await peer.fail("device '\(serial)' not found")
      } else {
        try await peer.answer(state.withLock { $0.features })
      }
      return
    }
    if !gone, try await forwardRequest(first, serial: serial, peer) { return }
    guard first == "host:transport:\(serial)", !gone else {
      try await peer.fail("device '\(serial)' not found")
      return
    }
    state.withLock { $0.peers.append(peer.stream) }
    try await peer.okay()
    let service = try await peer.request()
    try await peer.okay()
    state.withLock { $0.tools.services.append(service) }
    try await serve(service, peer)
  }

  /// Runs the service a connection started.
  private func serve(_ service: String, _ peer: Peer) async throws {
    if service == "sync:" {
      try await sync(peer)
    } else if service.hasPrefix("exec:") {
      try await exec(String(service.dropFirst("exec:".count)), peer)
    } else if service.hasPrefix("shell:") {
      try await legacyShell(String(service.dropFirst("shell:".count)), peer)
    } else if service.hasPrefix("shell,v2,raw:") {
      // The client closes stdin first.
      _ = try await peer.stream.read(exactly: 5)
      let command = String(service.dropFirst("shell,v2,raw:".count))
      if Self.words(command)?.first == "sh" {
        try await record(command, peer, legacyToken: nil)
        return
      }
      let program = command.split(separator: " ").first.map(String.init) ?? ""
      if state.withLock({ $0.hangingPrograms.contains(program) }) {
        // Answers nothing until the client gives up and closes.
        _ = try? await peer.stream.read(exactly: 1)
        return
      }
      let result = shell(command)
      var reply = Data()
      if !result.stdout.isEmpty { reply += Peer.shellPacket(1, Data(result.stdout.utf8)) }
      if !result.stderr.isEmpty { reply += Peer.shellPacket(2, Data(result.stderr.utf8)) }
      try await peer.raw(reply + Peer.shellPacket(3, Data([UInt8(result.status)])))
    } else {
      throw ScriptError.unexpected(service)
    }
  }

  // MARK: sync

  private static let enoent: UInt32 = 2

  private func sync(_ peer: Peer) async throws {
    state.withLock { $0.openSyncs += 1 }
    defer { state.withLock { $0.openSyncs -= 1 } }
    while true {
      let (id, length) = try await peer.syncHeader()
      if id == "QUIT" { return }
      let path = Array(try await peer.stream.read(exactly: Int(length)))
      let hooks = state.withLock { state in
        state.syncRequests.append((id, FakeAndroid.text(path)))
        guard let index = state.beforeSync.firstIndex(where: { $0.id == id }) else {
          return [(id: String, action: @Sendable (FakeAndroid) -> Void)]()
        }
        return [state.beforeSync.remove(at: index)]
      }
      for hook in hooks { hook.action(self) }
      switch id {
      case "STA2":
        let node = state.withLock { $0.node(at: path) }
        try await peer.raw(
          node.map { Peer.sta2(mode: Self.mode($0), size: Self.size($0), mtime: Self.mtime($0)) }
            ?? Peer.sta2(error: Self.enoent, mode: 0, size: 0, mtime: 0))
      case "STAT":
        let node = state.withLock { $0.node(at: path) }
        try await peer.raw(
          Peer.stat(
            mode: node.map(Self.mode) ?? 0,
            size: UInt32(truncatingIfNeeded: node.map(Self.size) ?? 0),
            mtime: UInt32(truncatingIfNeeded: node.map(Self.mtime) ?? 0)))
      case "LIST":
        try await peer.raw(list(path) + Peer.listDone(extended: false))
      case "RECV":
        guard try await receive(path, peer) else { return }
      case "SEND":
        guard try await send(path, peer) else { return }
      default:
        throw ScriptError.unexpected(id)
      }
    }
  }

  static func mode(_ node: Node) -> UInt32 {
    switch node {
    case .folder: 0o40771
    case .file: 0o100660
    case .special: 0o140755
    }
  }

  static func size(_ node: Node) -> UInt64 {
    switch node {
    case .folder: 4096
    case .file(let data, _): UInt64(data.count)
    case .special: 0
    }
  }

  static func mtime(_ node: Node) -> Int64 {
    switch node {
    case .folder(let mtime), .file(_, let mtime): mtime
    case .special: 0
    }
  }

  /// `LIST` answers a path that is not a folder with no entries, not an error, and lists `.`
  /// and `..` first, as `readdir` gives them to adbd.
  private func list(_ path: Path) -> Data {
    state.withLock { state in
      guard let folder = state.resolve(path), case .folder = state.nodes[folder] else {
        return Data()
      }
      var reply = Data()
      let dots: [(name: Path, node: Node)] = [
        (Array(".".utf8), .folder(mtime: 1)), (Array("..".utf8), .folder(mtime: 1)),
      ]
      let entries = state.children(of: folder).map {
        (FakeAndroid.name($0), state.nodes[$0] ?? .special)
      }
      for (name, node) in dots + entries {
        reply += Data("DENT".utf8) + Peer.le32(Self.mode(node))
        reply += Peer.le32(UInt32(truncatingIfNeeded: Self.size(node)))
        reply += Peer.le32(UInt32(truncatingIfNeeded: Self.mtime(node)))
        reply += Peer.le32(UInt32(name.count)) + Data(name)
      }
      return reply
    }
  }

  /// False once the session is over: adbd ends it after a failed `RECV`.
  private func receive(_ path: Path, _ peer: Peer) async throws -> Bool {
    let node = state.withLock { $0.node(at: path) }
    guard case .file(let data, _) = node else {
      let reason =
        node == nil ? "open failed: No such file or directory" : "read failed: Is a directory"
      try await peer.raw(Peer.fail(reason))
      return false
    }
    var offset = 0
    while offset < data.count {
      let end = min(offset + 65_536, data.count)
      try await peer.raw(Peer.data(data[offset..<end]))
      offset = end
      if let drop = state.withLock({ $0.dropAfterBytes }), drop.id == "RECV", offset >= drop.bytes {
        unplug()
        return false
      }
    }
    try await peer.raw(Peer.done())
    return true
  }

  /// adbd's `do_send`: the path ends at the last comma; an existing file goes before anything
  /// arrives; missing folders are made; a broken transfer removes what it wrote.
  private func send(_ spec: Path, _ peer: Peer) async throws -> Bool {
    guard let comma = spec.lastIndex(of: UInt8(ascii: ",")) else {
      throw ScriptError.unexpected("SEND")
    }
    guard let target = state.withLock({ $0.create(Array(spec[..<comma])) }) else {
      try await peer.raw(Peer.fail("couldn't create file: Is a directory"))
      try await drain(peer)
      return false
    }
    do {
      let finished = try await receiveData(into: target, peer)
      if !finished { state.withLock { $0.nodes[target] = nil } }
      return finished
    } catch {
      // The client hung up mid-transfer (a cancel): adbd unlinks the file it was writing.
      state.withLock { $0.nodes[target] = nil }
      throw error
    }
  }

  /// Reads `DATA` into `target` until `DONE`, whose argument is the file's date. False when the
  /// device failed the write or dropped off.
  private func receiveData(into target: Path, _ peer: Peer) async throws -> Bool {
    var received = Data()
    while true {
      let (id, length) = try await peer.syncHeader()
      if id == "DONE" {
        state.withLock { [received] in $0.nodes[target] = .file(received, mtime: Int64(length)) }
        try await peer.raw(Data("OKAY".utf8) + Peer.le32(0))
        return true
      }
      guard id == "DATA" else { throw ScriptError.unexpected(id) }
      received += try await peer.stream.read(exactly: Int(length))
      if let failure = state.withLock({ $0.sendFailure }) {
        state.withLock { $0.sendFailure = nil }
        try await peer.raw(Peer.fail(failure))
        try await drain(peer)
        return false
      }
      let drop = state.withLock { $0.dropAfterBytes }
      if drop?.id == "SEND", received.count >= drop?.bytes ?? .max {
        unplug()
        return false
      }
    }
  }

  /// Reads and drops `DATA` until `DONE`, as adbd does after reporting a failed `SEND`.
  private func drain(_ peer: Peer) async throws {
    while true {
      let (id, length) = try await peer.syncHeader()
      if id == "DONE" { return }
      _ = try await peer.stream.read(exactly: Int(length))
    }
  }
}
