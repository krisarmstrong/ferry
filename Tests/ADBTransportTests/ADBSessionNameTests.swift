import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Review Focus 3: names the device's shell would read as syntax. Each one goes up, is listed,
/// renamed, moved, made as a folder and deleted with its exact bytes, and every command the
/// device runs names exactly the paths meant: the fake's `sh` refuses anything that escapes its
/// quoting, and the whole tree is checked after each step, so a stray path cannot pass unseen.
struct ADBSessionNameTests {
  static let names = [
    "it's", "$HOME", "$(reboot)", "back\\slash", "-rf", "--", "line\nbreak", "emoji 😀", "a,b",
    "semi;colon", "`tick`", "\"quoted\"", "*", "~", "#hash", "tab\there", "'; rm -r '",
  ]

  let storage = ADBFixture.storage
  let root = FakeAndroid.internalRoot

  @Test(arguments: names)
  func aNameRoundTripsThroughEveryOperation(_ name: String) async throws {
    let device = FakeAndroid()
    device.addFolder("/Box")
    device.addFile("/keep.txt", Data("keep".utf8))
    let file = try ADBFixture.localFile(Data("payload".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let named = try RemotePath.root.appending(name)
    let renamed = try RemotePath.root.appending(name + "2")
    let moved = try RemotePath("/Box").appending(name + "2")

    try await ADBFixture.withSession(device) { session in
      let uploaded = try await session.upload(
        from: file, to: named, in: storage, progress: ADBFixture.noProgress)
      #expect(uploaded.path == named)
      #expect(device.tree == ["/" + name, "/Box", "/keep.txt"].sorted())
      let listed = try await session.list(.root, in: storage)
      #expect(listed.map(\.path).contains(named))

      _ = try await session.rename(named, to: name + "2", in: storage)
      #expect(device.tree == ["/" + name + "2", "/Box", "/keep.txt"].sorted())

      _ = try await session.move(renamed, toFolder: RemotePath("/Box"), in: storage)
      #expect(device.tree == ["/Box", "/Box/" + name + "2", "/keep.txt"])
      #expect(device.contents("/Box/" + name + "2") == Data("payload".utf8))

      _ = try await session.makeFolder(named, in: storage)
      #expect(device.tree == ["/" + name, "/Box", "/Box/" + name + "2", "/keep.txt"].sorted())

      try await session.delete(moved, in: storage)
      try await session.delete(named, in: storage)
      #expect(device.tree == ["/Box", "/keep.txt"])
    }
    #expect(
      device.changes == [
        ["mv", "-n", "--", root + "/" + name, root + "/" + name + "2"],
        ["mv", "-n", "--", root + "/" + name + "2", root + "/Box/" + name + "2"],
        ["mkdir", "--", root + "/" + name],
        ["rm", "--", root + "/Box/" + name + "2"],
        ["rm", "-r", "--", root + "/" + name],
      ])
  }

  /// Every argument is single-quoted, so the device's `sh` hands each one over unread.
  @Test func shellArgumentsAreQuotedWhole() throws {
    let command = try ADBShell.command("rm", ["--", "/x/it's $HOME\n"])
    #expect(command == "rm '--' '/x/it'\\''s $HOME\n'")
    #expect(FakeAndroid.words(command) == ["rm", "--", "/x/it's $HOME\n"])
    #expect(FakeAndroid.words("rm /x/$HOME") == nil)
  }
}
