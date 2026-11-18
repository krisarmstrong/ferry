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

  @Test func staleBackupIsLeftAloneWhileAWriteInItsFolderIsInFlight() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let backup = try RemotePath("/" + SafeWriter.backupName(for: "a.txt"))
    try await device.seed(backup, in: storageID, contents: Data([9]))
    let partial = try RemotePath("/\(SafeWriter.partialPrefix)\(UUID().uuidString)")
    await device.partials.registerInFlight(partial, in: storageID)

    #expect(try await writer.visibleList(.root, in: storageID).isEmpty)
    #expect(await device.allPaths(in: storageID) == [backup])
  }

  /// Unplugged between setting the old file aside and renaming the new one into place: the old
  /// file survives only as a backup. The next session puts it back under its name.
  @Test func backupLeftByAnUnplugIsRestoredByTheNextSession() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    // The partial's rename and the restore both fail, as when the cable is pulled.
    await device.failRename(with: .deviceDisconnected, skipping: 1, count: 2)
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.deviceDisconnected) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    #expect(await device.contents(of: path, in: storageID) == nil)

    let later = await device.newSession()
    let listed = try await SafeWriter(session: later).visibleList(.root, in: storageID)

    #expect(listed.map(\.path) == [path])
    #expect(await later.contents(of: path, in: storageID) == Data([9]))
    #expect(await later.allPaths(in: storageID) == [path])
  }

  /// The new file made it into place but the backup's delete failed: the next session deletes
  /// the backup, having checked the file at its name is a complete file.
  @Test func backupWhoseNameHoldsTheNewFileIsDeletedByTheNextSession() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    await device.failNextDelete(with: .io("delete failed"))
    try await withTempFile(Data([1, 2])) { file in
      _ = try await writer.write(from: file, to: path, replacing: true)
    }

    let later = await device.newSession()
    let listed = try await SafeWriter(session: later).visibleList(.root, in: storageID)

    #expect(listed.map(\.path) == [path])
    #expect(await later.allPaths(in: storageID) == [path])
    #expect(await later.contents(of: path, in: storageID) == Data([1, 2]))
  }

  /// Never deleted blindly: a backup whose name is now a folder, or whose original name cannot
  /// be read, stays (hidden).
  @Test func backupThatCannotBeResolvedIsKept() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let shadowed = try RemotePath("/" + SafeWriter.backupName(for: "a"))
    let unnamed = try RemotePath("/\(SafeWriter.backupPrefix)\(UUID().uuidString)")
    try await device.seed(shadowed, in: storageID, contents: Data([9]))
    try await device.seed(unnamed, in: storageID, contents: Data([8]))
    _ = try await device.makeFolder(RemotePath("/a"), in: storageID)

    #expect(
      try await writer.visibleList(.root, in: storageID).map(\.path) == [try RemotePath("/a")])
    #expect(await device.contents(of: shadowed, in: storageID) == Data([9]))
    #expect(await device.contents(of: unnamed, in: storageID) == Data([8]))
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

  /// The device stored the set-aside copy under another name, which would leave the user's file
  /// renamed to something odd. It is renamed back, and the replace fails with the device's
  /// change.
  @Test func aBackupTheDeviceRenamedIsPutBack() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    await device.storeBackups(as: "FERRY~1")
    try await withTempFile(Data([1, 2])) { file in
      await #expect {
        _ = try await writer.write(from: file, to: path, replacing: true)
      } throws: { error in
        if case TransportError.nameChangedByDevice(_, "FERRY~1") = error { return true }
        return false
      }
    }
    #expect(await device.allPaths(in: storageID) == [path])
    #expect(await device.contents(of: path, in: storageID) == Data([9]))
  }

  /// A device that cannot rename deletes the old file before the upload goes up under its name:
  /// the delete must be of the file the write checked, not one the device swapped in meanwhile.
  @Test func aNoRenameReplaceKeepsAFileSwappedInDuringTheUpload() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    let checked = try await device.item(at: path, in: storageID)
    await device.failRename(with: .unsupported("rename"), count: 10)
    let storage = storageID
    await device.onNextUpload {
      try? await device.seed(path, in: storage, contents: Data("swapped on the unit".utf8))
    }
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.changedOnDevice(path)) {
        _ = try await writer.write(
          from: file, to: path, in: storage, replacing: true, expecting: checked,
          progress: { _, _ in true })
      }
    }
    #expect(await device.contents(of: path, in: storageID) == Data("swapped on the unit".utf8))
  }

  /// A backup's name must fit what PTP carries: 255 UTF-8 bytes and 254 UTF-16 units.
  @Test func aBackupNameThatWouldNotFitNamesNoOriginal() {
    let longest = SafeWriter.backupName(for: String(repeating: "a", count: 204))
    #expect(SafeWriter.originalName(ofBackup: longest) == nil)
    let fits = SafeWriter.backupName(for: String(repeating: "a", count: 203))
    #expect(SafeWriter.originalName(ofBackup: fits) == String(repeating: "a", count: 203))
  }
}
