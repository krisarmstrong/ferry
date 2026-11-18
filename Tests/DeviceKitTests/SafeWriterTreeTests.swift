import DeviceKitTestSupport
import Foundation
import Testing

@testable import DeviceKit

/// A package goes up whole: built under a hidden partial name, renamed into place only once
/// complete, and on a replace the old one is set aside until the new one is in place.
extension SafeWriterTests {
  /// A local package folder holding `TXT.rtf` and `Media/a.png`.
  func localPackage(_ text: String) throws -> URL {
    let folder = try TestScratch.folder("package")
    let package = folder.appending(path: "Notes.rtfd")
    try FileManager.default.createDirectory(
      at: package.appending(path: "Media"), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: package.appending(path: "TXT.rtf"))
    try Data("png".utf8).write(to: package.appending(path: "Media/a.png"))
    return package
  }

  @Test func aTreeGoesUpUnderAPartialThenTakesItsName() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let local = try localPackage("new")
    defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
    let path = try RemotePath("/Notes.rtfd")

    let item = try await writer.writeTree(from: local, to: path, in: storageID, replacing: false)

    #expect(item.path == path)
    #expect(item.kind == .folder)
    #expect(
      await device.contents(of: try RemotePath("/Notes.rtfd/TXT.rtf"), in: storageID)
        == Data("new".utf8))
    #expect(
      await device.contents(of: try RemotePath("/Notes.rtfd/Media/a.png"), in: storageID)
        == Data("png".utf8))
    #expect(await partials(device).isEmpty)
  }

  @Test func aTreeReplacesTheOldOneWhole() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    try await device.seed(
      try RemotePath("/Notes.rtfd/TXT.rtf"), in: storageID, contents: Data("old".utf8))
    try await device.seed(
      try RemotePath("/Notes.rtfd/gone.png"), in: storageID, contents: Data("x".utf8))
    let local = try localPackage("new")
    defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }

    _ = try await writer.writeTree(
      from: local, to: try RemotePath("/Notes.rtfd"), in: storageID, replacing: true)

    #expect(
      await device.allPaths(in: storageID).map(\.description) == [
        "/Notes.rtfd", "/Notes.rtfd/Media", "/Notes.rtfd/Media/a.png", "/Notes.rtfd/TXT.rtf",
      ])
    #expect(
      await device.contents(of: try RemotePath("/Notes.rtfd/TXT.rtf"), in: storageID)
        == Data("new".utf8))
  }

  /// The new tree cannot take the name: the old one comes back, and nothing else is left.
  @Test func aReplaceWhoseFinalRenameFailsRestoresTheOldTree() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    try await device.seed(
      try RemotePath("/Notes.rtfd/TXT.rtf"), in: storageID, contents: Data("old".utf8))
    let local = try localPackage("new")
    defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
    // The first rename sets the old tree aside; the second, the partial's, fails.
    await device.failRename(with: .io("rename failed"), skipping: 1)

    await #expect(throws: TransportError.io("rename failed")) {
      _ = try await writer.writeTree(
        from: local, to: try RemotePath("/Notes.rtfd"), in: storageID, replacing: true)
    }

    #expect(
      await device.allPaths(in: storageID).map(\.description) == [
        "/Notes.rtfd", "/Notes.rtfd/TXT.rtf",
      ])
    #expect(
      await device.contents(of: try RemotePath("/Notes.rtfd/TXT.rtf"), in: storageID)
        == Data("old".utf8))
  }

  @Test func aTreeDoesNotTakeAnExistingNameUnlessReplacing() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    try await device.seed(
      try RemotePath("/Notes.rtfd/TXT.rtf"), in: storageID, contents: Data("old".utf8))
    let local = try localPackage("new")
    defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }

    await #expect(throws: TransportError.alreadyExists(try RemotePath("/Notes.rtfd"))) {
      _ = try await writer.writeTree(
        from: local, to: try RemotePath("/Notes.rtfd"), in: storageID, replacing: false)
    }
  }
}
