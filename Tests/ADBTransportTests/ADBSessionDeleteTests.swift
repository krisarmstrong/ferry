import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// `delete(_:in:expecting:)` and how failed shell commands surface, against `MTPSession`.
struct ADBSessionDeleteTests {
  let storage = ADBFixture.storage

  func path(_ string: String) throws -> RemotePath { try ADBFixture.path(string) }

  /// What a caller checked: the listing of `folder` and of every folder in it.
  func checked(_ folder: String, on session: ADBSession) async throws -> [RemoteItem] {
    let top = try await session.item(at: path(folder), in: storage)
    var items = [top]
    var pending = top.kind == .folder ? [top] : []
    while let next = pending.popLast() {
      let children = try await session.list(next.path, in: storage)
      items += children
      pending += children.filter { $0.kind == .folder }
    }
    return items
  }

  @Test func deleteRemovesAFileOrAFolderWithItsContents() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    device.addFolder("/F")
    device.addFile("/F/b.txt", Data("b".utf8))
    try await ADBFixture.withSession(device) { session in
      try await session.delete(path("/a.txt"), in: storage)
      try await session.delete(path("/F"), in: storage)
    }
    #expect(device.tree.isEmpty)
    #expect(
      device.changes == [
        ["rm", "--", "/storage/emulated/0/a.txt"], ["rm", "-r", "--", "/storage/emulated/0/F"],
      ])
  }

  @Test(arguments: ["/none", "/"])
  func deletingNothingOrTheRootIsNotFound(_ name: String) async throws {
    await #expect(throws: TransportError.notFound(try path(name))) {
      try await ADBFixture.withSession(FakeAndroid()) {
        try await $0.delete(path(name), in: storage)
      }
    }
  }

  @Test func aCheckedTreeIsDeleted() async throws {
    let device = FakeAndroid()
    device.addFolder("/F")
    device.addFile("/F/a.txt", Data("a".utf8))
    device.addFolder("/F/G")
    device.addFile("/F/G/b.txt", Data("b".utf8))
    try await ADBFixture.withSession(device) { session in
      let seen = try await checked("/F", on: session)
      try await session.delete(path("/F"), in: storage, expecting: seen)
    }
    #expect(device.tree.isEmpty)
  }

  @Test func aFileReplacedSinceTheCheckIsNotDeleted() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    let file = try path("/a.txt")
    try await ADBFixture.withSession(device) { session in
      let seen = try await checked("/a.txt", on: session)
      device.addFile("/a.txt", Data("changed".utf8))
      await #expect(throws: TransportError.changedOnDevice(file)) {
        try await session.delete(path("/a.txt"), in: storage, expecting: seen)
      }
    }
    #expect(device.contents("/a.txt") == Data("changed".utf8))
  }

  @Test func aFolderThatGainedAnItemIsNotDeletedAtAll() async throws {
    let device = FakeAndroid()
    device.addFolder("/F")
    device.addFolder("/F/G")
    device.addFile("/F/G/a.txt", Data("a".utf8))
    let folder = try path("/F")
    try await ADBFixture.withSession(device) { session in
      let seen = try await checked("/F", on: session)
      device.addFile("/F/G/new.txt", Data("n".utf8))
      await #expect(throws: TransportError.directoryNotEmpty(folder)) {
        try await session.delete(path("/F"), in: storage, expecting: seen)
      }
    }
    #expect(device.tree == ["/F", "/F/G", "/F/G/a.txt", "/F/G/new.txt"])
    #expect(device.changes.isEmpty)
  }

  @Test func theCheckedTreeGoesWithItsHiddenPartials() async throws {
    let device = FakeAndroid()
    device.addFolder("/F")
    device.addFile("/F/a.txt", Data("a".utf8))
    try await ADBFixture.withSession(device) { session in
      let seen = try await checked("/F", on: session)
      device.addFile("/F/.ferry-partial-X", Data("p".utf8))
      try await session.delete(path("/F"), in: storage, expecting: seen)
    }
    #expect(device.tree.isEmpty)
  }

  /// Finder never saw a name the listing skips, so a checked delete must not sweep it away.
  @Test(arguments: [[UInt8]([0x62, 0xFF]), Array("Cafe\u{301}".utf8)])
  func aFolderHoldingAnUnlistedNameIsKeptByACheckedDelete(_ name: [UInt8]) async throws {
    let device = FakeAndroid()
    device.addFolder("/F")
    device.addFile("/F/a.txt", Data("a".utf8))
    let folder = try path("/F")
    try await ADBFixture.withSession(device) { session in
      let seen = try await checked("/F", on: session)
      device.addRaw("/F", name: name, node: .file(Data("x".utf8), mtime: 1))
      await #expect(throws: TransportError.directoryNotEmpty(folder)) {
        try await session.delete(path("/F"), in: storage, expecting: seen)
      }
    }
    #expect(device.contents("/F/a.txt") == Data("a".utf8))
  }

  @Test(arguments: [RemotePath.maxTreeDepth, RemotePath.maxTreeDepth + 1])
  func aCheckedTreeDeeperThanFerryWalksIsRefused(_ depth: Int) async throws {
    let device = FakeAndroid()
    var folder = "/F"
    device.addFolder(folder)
    for _ in 0..<depth {
      folder += "/d"
      device.addFolder(folder)
    }
    let top = try path("/F")
    try await ADBFixture.withSession(device) { session in
      let seen = try await checked("/F", on: session)
      if depth > RemotePath.maxTreeDepth {
        await #expect(throws: TransportError.folderTooDeep(top)) {
          try await session.delete(path("/F"), in: storage, expecting: seen)
        }
      } else {
        try await session.delete(path("/F"), in: storage, expecting: seen)
      }
    }
    #expect(device.tree.isEmpty == (depth <= RemotePath.maxTreeDepth))
  }

  // MARK: Shell failures

  /// A command's failure, by its message, as the matching `TransportError`.
  @Test(
    arguments: [
      ("rm: /storage/emulated/0/F: Directory not empty", TransportError.directoryNotEmpty(.root)),
      ("rm: /storage/emulated/0/F: No such file or directory", .notFound(.root)),
      ("rm: x: Permission denied", .io("delete failed: rm: x: Permission denied")),
      ("rm: x: Read-only file system", .io("delete failed: rm: x: Read-only file system")),
    ])
  func aFailedRmIsMapped(_ message: String, _ expected: TransportError) async throws {
    let device = FakeAndroid()
    device.addFolder("/F")
    device.failNextShell("rm", stderr: message)
    let folder = try path("/F")
    let error = await #expect(throws: TransportError.self) {
      try await ADBFixture.withSession(device) { try await $0.delete(folder, in: storage) }
    }
    let wanted: TransportError =
      switch expected {
      case .directoryNotEmpty: .directoryNotEmpty(folder)
      case .notFound: .notFound(folder)
      default: expected
      }
    #expect(error == wanted)
  }

  /// `rm -r` that removed part of a tree and failed on the rest reports a child's error (toybox
  /// names the child alone): only a message about the folder itself names a specific cause.
  @Test(
    arguments: [
      "rm: x.txt: Permission denied\nrm: /storage/emulated/0/F: Directory not empty",
      "rm: x.txt: No such file or directory",
    ])
  func aPartlyFailedRecursiveDeleteIsAnIOError(_ message: String) async throws {
    let device = FakeAndroid()
    device.addFolder("/F")
    device.addFile("/F/x.txt", Data("x".utf8))
    device.addFile("/F/y.txt", Data("y".utf8))
    device.beforeNextShell("rm") {
      $0.state.withLock { $0.nodes[FakeAndroid.internalPath("/F/y.txt")] = nil }
    }
    device.failNextShell("rm", stderr: message)
    let folder = try path("/F")
    await #expect(throws: TransportError.io("delete failed: " + message)) {
      try await ADBFixture.withSession(device) { try await $0.delete(folder, in: storage) }
    }
  }

  /// A message that is not UTF-8 (it names a child whose name is not) keeps its text and its
  /// cause.
  @Test func aMessageThatIsNotUTF8IsKept() {
    let result = ADBShellResult(
      status: 1, stdout: Data(),
      stderr: Data([0x72, 0x6D, 0x3A, 0x20, 0xFF]) + Data(": Permission denied\n".utf8))
    let message = ADBSession.message(of: result)
    #expect(message.hasPrefix("rm: "))
    #expect(message.hasSuffix(": Permission denied"))
  }

  @Test func aFailedMkdirOrMvIsMapped() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    device.failNextShell("mkdir", stderr: "mkdir: '/storage/emulated/0/New': File exists")
    device.failNextShell("mv", stderr: "mv: bad '/storage/emulated/0/a.txt': Permission denied")
    let folder = try path("/New")
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.alreadyExists(folder)) {
        _ = try await session.makeFolder(folder, in: storage)
      }
      await #expect(
        throws: TransportError.io(
          "rename failed: mv: bad '/storage/emulated/0/a.txt': Permission denied")
      ) {
        _ = try await session.rename(path("/a.txt"), to: "b.txt", in: storage)
      }
    }
  }
}
