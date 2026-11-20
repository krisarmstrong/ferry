import Darwin
import Foundation
import os

/// Files that passed a check, each remembered with its device, inode, size and modification
/// time: the same file is not checked again until any of those change, so finding the fetched
/// adb on every scan does not hash 20 MB each time. Only passes are remembered.
final class VerifiedFiles: Sendable {
  private struct Stamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let seconds: Int
    let nanoseconds: Int

    init?(_ file: URL) {
      var info = stat()
      guard stat(file.path, &info) == 0 else { return nil }
      device = info.st_dev
      inode = info.st_ino
      size = info.st_size
      seconds = info.st_mtimespec.tv_sec
      nanoseconds = info.st_mtimespec.tv_nsec
    }
  }

  private let checkFile: @Sendable (URL) throws(PlatformToolsError) -> Void
  private let passed = OSAllocatedUnfairLock<[String: Stamp]>(initialState: [:])

  init(check: @escaping @Sendable (URL) throws(PlatformToolsError) -> Void) {
    checkFile = check
  }

  /// Throws `.notSigned` for a missing file, and whatever the check throws. A file that changed
  /// while it was checked is not remembered.
  func check(_ file: URL) throws(PlatformToolsError) {
    guard let before = Stamp(file) else { throw .notSigned }
    if passed.withLock({ $0[file.path] }) == before { return }
    passed.withLock { $0[file.path] = nil }
    try checkFile(file)
    if Stamp(file) == before { passed.withLock { $0[file.path] = before } }
  }
}
