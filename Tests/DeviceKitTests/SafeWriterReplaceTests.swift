import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

/// A replace sets the old file aside until the new one is in place.
extension SafeWriterTests {
  /// The old file is set aside, not deleted, until the new one is in place: if that last rename
  /// fails, the old file goes back.
  @Test func replaceWhoseFinalRenameFailsRestoresTheOriginal() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    // The first rename sets the original aside; the second, the partial's, fails.
    await device.failRename(with: .io("rename failed"), skipping: 1)
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.io("rename failed")) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    #expect(await device.contents(of: path, in: storageID) == Data([9]))
    #expect(await device.allPaths(in: storageID) == [path])
  }

  @Test func replaceWhoseSetAsideFailsLeavesTheOriginal() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    await device.failRename(with: .deviceBusy)
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.deviceBusy) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    #expect(await device.allPaths(in: storageID) == [path])
    #expect(await device.contents(of: path, in: storageID) == Data([9]))
  }

  /// The new file is in place; the old one, which could not be deleted, stays hidden and kept for
  /// the rest of the session. In a later session it is a stale backup, which a listing removes
  /// (see `staleBackupIsKeptWhileAWriteInItsFolderIsInFlight`).
  @Test func replaceWhoseBackupCannotBeDeletedSucceedsAndKeepsTheBackupHidden() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    await device.failNextDelete(with: .io("delete failed"))
    try await withTempFile(Data([1, 2])) { file in
      _ = try await writer.write(from: file, to: path, replacing: true)
    }
    #expect(await device.contents(of: path, in: storageID) == Data([1, 2]))
    #expect(try await writer.visibleList(.root, in: storageID).map(\.path) == [path])
    let backups = await device.allPaths(in: storageID).filter {
      SafeWriter.isBackup($0.name ?? "")
    }
    #expect(backups.count == 1)
    #expect(await device.contents(of: backups[0], in: storageID) == Data([9]))
  }

  @Test func staleBackupIsKeptWhileAWriteInItsFolderIsInFlight() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let backup = try RemotePath("/\(SafeWriter.backupPrefix)\(UUID().uuidString)")
    try await device.seed(backup, in: storageID, contents: Data([9]))
    let partial = try RemotePath("/\(SafeWriter.partialPrefix)\(UUID().uuidString)")
    await device.partials.registerInFlight(partial, in: storageID)

    #expect(try await writer.visibleList(.root, in: storageID).isEmpty)
    #expect(await device.allPaths(in: storageID) == [backup])

    await device.partials.unregisterInFlight(partial, in: storageID)
    #expect(try await writer.visibleList(.root, in: storageID).isEmpty)
    #expect(await device.allPaths(in: storageID).isEmpty)
  }

  /// Only a device that cannot rename gets a direct upload; a failed rename must not.
  @Test func renameIOFailureDoesNotFallBackToDirectUpload() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    await device.failRename(with: .io("rename failed"))
    try await withTempFile(Data([1, 2, 3])) { file in
      await #expect(throws: TransportError.io("rename failed")) {
        _ = try await writer.write(from: file, to: path, replacing: false)
      }
    }
    #expect(await device.allPaths(in: storageID).isEmpty)
  }
}
