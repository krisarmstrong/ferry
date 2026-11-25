import DeviceKitTestSupport
import Foundation
import Testing

@testable import DeviceKit

/// A backup is the only copy of the original while a no-rename replace runs: it must be whole
/// before the original goes, whole before it goes back up, and kept until the device is seen to
/// hold the original.
extension SafeWriterTests {
  static func dataFiles(_ backups: ReplaceBackups) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: backups.folder.path)) ?? []
    return names.filter { $0.hasSuffix(".data") }.map { backups.folder.appending(path: $0) }
  }

  /// The transport reports the copy done with bytes missing: the replace is refused and the
  /// original is never deleted.
  @Test func aShortBackupRefusesTheReplace() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    await device.shortenNextDownload(to: 5)
    try await withTempFile(Self.replacement) { file in
      await #expect(
        throws: TransportError.downloadSizeMismatch(
          listed: UInt64(Self.original.count), received: 5)
      ) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    #expect(await device.contents(of: path, in: storageID) == Self.original)
    #expect(backupFiles(backups).isEmpty)
  }

  /// The backup's bytes changed on the Mac after they were recorded: they are never uploaded.
  /// They are set aside for the user, and the device is left without a damaged copy.
  @Test func aTornBackupIsNeverUploaded() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    // Torn once the original is deleted, before the failed upload needs the backup. The first
    // delete is the discarded partial's, made before the backup.
    await device.onNextDelete {
      await device.onNextDelete {
        for file in Self.dataFiles(backups) { try? Data("torn".utf8).write(to: file) }
      }
    }
    await device.failUpload(afterBytes: 0, with: .io("refused"), skipping: 1)
    try await withTempFile(Self.replacement) { file in
      await #expect(throws: TransportError.io("refused")) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    #expect(await device.contents(of: path, in: storageID) == nil)
    #expect(backupFiles(backups) == ["Kept"])
  }

  /// The original went back but could not be read back to check it: the backup stays until a
  /// later listing reads the device's copy and finds it whole.
  @Test func aRestoreThatCannotBeReadBackKeepsTheBackup() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    await device.failUpload(afterBytes: 0, with: .io("refused"), skipping: 1)
    // The first download makes the backup; the second is the read-back.
    await device.failDownload(afterBytes: 0, with: .io("unreadable"), skipping: 1)
    try await withTempFile(Self.replacement) { file in
      _ = try? await writer.write(from: file, to: path, replacing: true)
    }
    #expect(await device.contents(of: path, in: storageID) == Self.original)
    #expect(backupFiles(backups).count == 3)

    _ = try await SafeWriter(session: device, backups: backups).visibleList(
      .root, in: storageID)
    #expect(backupFiles(backups).isEmpty)
    #expect(await device.contents(of: path, in: storageID) == Self.original)
  }

  /// A restore the device cut off left the start of the original under its name: that copy is
  /// replaced by the whole original.
  @Test func aRestoreCutShortIsRepaired() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    await device.disconnectDuringUpload(afterBytes: 3, skipping: 1)
    try await withTempFile(Self.replacement) { file in
      _ = try? await SafeWriter(session: device, backups: backups).write(
        from: file, to: path, replacing: true)
    }
    let later = await device.newSession()
    try await later.seed(path, in: storageID, contents: Self.original.prefix(6))

    let listed = try await SafeWriter(session: later, backups: backups).visibleList(
      .root, in: storageID)

    #expect(listed.map(\.path) == [path])
    #expect(Self.sha(await later.contents(of: path, in: storageID)) == Self.sha(Self.original))
    #expect(backupFiles(backups).isEmpty)
  }

  /// No free space figure is no proof of room: the replace is refused rather than run blind.
  @Test func aFolderWhoseFreeSpaceCannotBeReadRefusesTheCheck() {
    let nowhere = TestScratch.root.appending(path: "missing-\(UUID().uuidString)/x")
    #expect(throws: TransportError.self) {
      try LocalFile.requireSpace(1, at: nowhere)
    }
  }

  /// ferryctl keeps its backups where the agent does, which outlives a reboot and is settled by
  /// either.
  @Test func theStandardBackupFolderIsDurable() throws {
    let folder = try ReplaceBackups.standard().folder.path
    #expect(folder.contains("/Library/Application Support/"))
    #expect(!folder.hasPrefix(FileManager.default.temporaryDirectory.path))
  }

  /// The menu counts backups waiting for their device and files set aside for the user.
  @Test func backupsAreCounted() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    await device.disconnectDuringUpload(afterBytes: 3, skipping: 1)
    try await withTempFile(Self.replacement) { file in
      _ = try? await SafeWriter(session: device, backups: backups).write(
        from: file, to: path, replacing: true)
    }
    #expect(backups.counts() == (pending: 1, setAside: 0))

    let later = await device.newSession()
    try await later.seed(path, in: storageID, contents: Data("someone else's".utf8))
    _ = try await SafeWriter(session: later, backups: backups).visibleList(.root, in: storageID)
    #expect(backups.counts() == (pending: 0, setAside: 1))
  }
}
