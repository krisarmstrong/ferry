import CryptoKit
import DeviceKitTestSupport
import Foundation
import Testing
import os

@testable import DeviceKit

/// A device that cannot rename must delete the old file before the new one can go up under its
/// name. The old file is first copied to the Mac, and put back if the upload fails.
extension SafeWriterTests {
  static let original = Data("the original, which must survive".utf8)
  static let replacement = Data("the new contents".utf8)

  static func sha(_ data: Data?) -> String? {
    data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
  }

  /// A device whose renames all fail as unsupported, holding `original` at `/a.txt`.
  func noRenameDevice() async throws -> (FakeDevice, RemotePath) {
    let device = makeDevice()
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Self.original)
    await device.failRename(with: .unsupported("rename"), count: 1000)
    return (device, path)
  }

  func backupFiles(_ backups: ReplaceBackups) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: backups.folder.path)) ?? []).sorted()
  }

  @Test func aNoRenameReplaceLeavesTheNewContentsAndNoBackup() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    try await withTempFile(Self.replacement) { file in
      let item = try await writer.write(from: file, to: path, replacing: true)
      #expect(item.size == UInt64(Self.replacement.count))
    }
    #expect(Self.sha(await device.contents(of: path, in: storageID)) == Self.sha(Self.replacement))
    #expect(await device.allPaths(in: storageID) == [path])
    #expect(backupFiles(backups).isEmpty)
  }

  /// The direct upload fails with the device still there: the original goes back at once,
  /// byte for byte, and the backup is gone.
  @Test(arguments: [
    TransportError.io("refused by the device"), .insufficientSpace(needed: 0, free: 0),
    .deviceBusy, .unsupported("uploading"),
  ])
  func aFailedNoRenameUploadPutsTheOriginalBack(_ failure: TransportError) async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    // The partial goes up first and is discarded when the device cannot rename the original.
    await device.failUpload(afterBytes: 3, with: failure, skipping: 1)
    try await withTempFile(Self.replacement) { file in
      await #expect(throws: failure) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    #expect(Self.sha(await device.contents(of: path, in: storageID)) == Self.sha(Self.original))
    #expect(await device.allPaths(in: storageID) == [path])
    #expect(backupFiles(backups).isEmpty)
  }

  /// A cancel stops the upload; the restore is not the caller's transfer and still runs.
  @Test func aCancelledNoRenameReplacePutsTheOriginalBack() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    // The user cancels once the original is deleted, while the new contents go up.
    let cancelled = Flag()
    await device.onNextDelete { cancelled.set() }
    try await withTempFile(Self.replacement) { file in
      await #expect(throws: TransportError.cancelled) {
        _ = try await writer.write(
          from: file, to: path, in: storageID, replacing: true,
          progress: { _, _ in !cancelled.isSet })
      }
    }
    #expect(Self.sha(await device.contents(of: path, in: storageID)) == Self.sha(Self.original))
    #expect(backupFiles(backups).isEmpty)
  }

  /// Nothing is deleted when the original cannot be copied to the Mac: the replace is refused
  /// with the reason the copy failed.
  @Test func aNoRenameReplaceWhoseBackupFailsIsRefused() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    await device.failDownload(afterBytes: 4, with: .io("read refused"))
    try await withTempFile(Self.replacement) { file in
      await #expect(throws: TransportError.io("read refused")) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    #expect(await device.contents(of: path, in: storageID) == Self.original)
    #expect(await device.allPaths(in: storageID) == [path])
    #expect(backupFiles(backups).isEmpty)
  }

  /// Unplugged mid-upload: neither the clean-up nor the restore can reach the device, so the
  /// backup stays on the Mac and the next session puts the original back.
  @Test func anUnplugMidUploadIsRepairedByTheNextSession() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    await device.disconnectDuringUpload(afterBytes: 3, skipping: 1)
    try await withTempFile(Self.replacement) { file in
      await #expect(throws: TransportError.deviceDisconnected) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    // A short file under the real name, and the original only on the Mac.
    #expect(await device.contents(of: path, in: storageID) == Self.replacement.prefix(3))
    #expect(backupFiles(backups).count == 3)

    let later = await device.newSession()
    await later.failRename(with: .unsupported("rename"), count: 1000)
    let listed = try await SafeWriter(session: later, backups: backups).visibleList(
      .root, in: storageID)

    #expect(listed.map(\.path) == [path])
    #expect(Self.sha(await later.contents(of: path, in: storageID)) == Self.sha(Self.original))
    #expect(backupFiles(backups).isEmpty)
  }

  /// Unplugged once the new contents were all on the device: the replace finished, so the next
  /// session drops the backup and keeps the new file.
  @Test func aFinishedReplaceCutOffBeforeItsCleanUpKeepsTheNewFile() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    await device.disconnectDuringUpload(
      afterBytes: UInt64(Self.replacement.count), skipping: 1)
    try await withTempFile(Self.replacement) { file in
      await #expect(throws: TransportError.deviceDisconnected) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }

    let later = await device.newSession()
    let listed = try await SafeWriter(session: later, backups: backups).visibleList(
      .root, in: storageID)

    #expect(listed.map(\.path) == [path])
    #expect(Self.sha(await later.contents(of: path, in: storageID)) == Self.sha(Self.replacement))
    #expect(backupFiles(backups).isEmpty)
  }

  /// A file at the name that is neither the original nor the new one (the user put something
  /// else there meanwhile) is never overwritten: the original is set aside on the Mac.
  @Test func aBackupWhoseNameHoldsSomethingElseIsSetAside() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    let writer = SafeWriter(session: device, backups: backups)
    await device.disconnectDuringUpload(afterBytes: 3, skipping: 1)
    try await withTempFile(Self.replacement) { file in
      _ = try? await writer.write(from: file, to: path, replacing: true)
    }

    let later = await device.newSession()
    let other = Data("someone else's".utf8)
    try await later.seed(path, in: storageID, contents: other)
    _ = try await SafeWriter(session: later, backups: backups).visibleList(.root, in: storageID)

    #expect(await later.contents(of: path, in: storageID) == other)
    #expect(backupFiles(backups) == ["Kept"])
    #expect(try Data(contentsOf: backups.setAsideFolder.appending(path: "a.txt")) == Self.original)
  }

  /// The name is free and the folder holds what it held beside the original: the replace was
  /// cut off before its upload began, and the original goes back.
  @Test func aFreeNameInTheSameFolderGetsTheOriginalBack() async throws {
    let (device, path) = try await noRenameDevice()
    let sibling = try RemotePath("/notes.txt")
    try await device.seed(sibling, in: storageID, contents: Data("notes".utf8))
    let backups = ReplaceBackups.scratch()
    await device.disconnectDuringUpload(afterBytes: 0, skipping: 1)
    try await withTempFile(Self.replacement) { file in
      _ = try? await SafeWriter(session: device, backups: backups).write(
        from: file, to: path, replacing: true)
    }
    let later = await device.newSession()
    try await later.delete(path, in: storageID)

    let listed = try await SafeWriter(session: later, backups: backups).visibleList(
      .root, in: storageID)

    #expect(Set(listed.map(\.path)) == [path, sibling])
    #expect(Self.sha(await later.contents(of: path, in: storageID)) == Self.sha(Self.original))
    #expect(backupFiles(backups).isEmpty)
  }

  /// Another unit reporting the same serial, with a storage of the same size: its folder is not
  /// the one the backup came from, so nothing is written to it, and the original is set aside
  /// on the Mac where the menu points to it.
  @Test func aBackupIsNeverWrittenToAnotherUnitWithTheSameSerial() async throws {
    let (device, path) = try await noRenameDevice()
    try await device.seed(try RemotePath("/notes.txt"), in: storageID, contents: Data("n".utf8))
    let backups = ReplaceBackups.scratch()
    await device.disconnectDuringUpload(afterBytes: 0, skipping: 1)
    try await withTempFile(Self.replacement) { file in
      _ = try? await SafeWriter(session: device, backups: backups).write(
        from: file, to: path, replacing: true)
    }

    let impostor = makeDevice()
    let theirs = try RemotePath("/holiday.jpg")
    try await impostor.seed(theirs, in: storageID, contents: Data("theirs".utf8))
    let listed = try await SafeWriter(session: impostor, backups: backups).visibleList(
      .root, in: storageID)

    #expect(listed.map(\.path) == [theirs])
    #expect(await impostor.allPaths(in: storageID) == [theirs])
    #expect(backupFiles(backups) == ["Kept"])
    #expect(try Data(contentsOf: backups.setAsideFolder.appending(path: "a.txt")) == Self.original)
  }

  /// A storage of another size is never the one the backup came from.
  @Test func aBackupIsNeverWrittenToAStorageOfAnotherSize() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    await device.disconnectDuringUpload(afterBytes: 3, skipping: 1)
    try await withTempFile(Self.replacement) { file in
      _ = try? await SafeWriter(session: device, backups: backups).write(
        from: file, to: path, replacing: true)
    }
    let other = FakeDevice(
      info: DeviceInfo(id: deviceID, manufacturer: "Fake", model: "Phone"),
      storages: [
        StorageInfo(
          id: storageID, description: "Internal", capacity: 64_000_000_000, free: 5_000_000_000)
      ])

    #expect(
      try await SafeWriter(session: other, backups: backups).visibleList(.root, in: storageID)
        .isEmpty)
    #expect(await other.allPaths(in: storageID).isEmpty)
    #expect(backupFiles(backups) == ["Kept"])
  }

  /// Recovery is for this device's storage only.
  @Test func aBackupOfAnotherDeviceIsLeftAlone() async throws {
    let (device, path) = try await noRenameDevice()
    let backups = ReplaceBackups.scratch()
    await device.disconnectDuringUpload(afterBytes: 3, skipping: 1)
    try await withTempFile(Self.replacement) { file in
      _ = try? await SafeWriter(session: device, backups: backups).write(
        from: file, to: path, replacing: true)
    }
    let stranger = FakeDevice(
      info: DeviceInfo(id: DeviceID(serial: "OTHER"), manufacturer: "Fake", model: "Phone"),
      storages: [
        StorageInfo(
          id: StorageID(device: DeviceID(serial: "OTHER"), key: storageID.key),
          description: "Internal", capacity: 10_000_000_000, free: 5_000_000_000)
      ])
    let other = StorageID(device: DeviceID(serial: "OTHER"), key: storageID.key)
    #expect(
      try await SafeWriter(session: stranger, backups: backups).visibleList(.root, in: other)
        .isEmpty)
    #expect(await stranger.allPaths(in: other).isEmpty)
    #expect(backupFiles(backups).count == 3)
  }

  /// A backup whose copy never finished was made before the device's file was touched.
  @Test func sweepRemovesOnlyIncompleteBackups() throws {
    let backups = ReplaceBackups.scratch()
    try FileManager.default.createDirectory(at: backups.folder, withIntermediateDirectories: true)
    let complete = UUID().uuidString
    let incomplete = UUID().uuidString
    let orphanRecord = UUID().uuidString
    for name in [
      "\(complete).data", "\(complete).json", "\(incomplete).data", "\(orphanRecord).json",
      "\(UUID().uuidString).check",
    ] {
      try Data([1]).write(to: backups.folder.appending(path: name))
    }
    backups.sweepIncomplete()
    #expect(backupFiles(backups) == ["\(complete).data", "\(complete).json"].sorted())
  }
}

/// Set once, from any task.
final class Flag: Sendable {
  private let value = OSAllocatedUnfairLock(initialState: false)

  var isSet: Bool { value.withLock { $0 } }

  func set() {
    value.withLock { $0 = true }
  }
}
