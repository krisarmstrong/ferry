import Foundation

/// Which file is at an executable's path: its volume, inode, size and modification time. An
/// update puts a new file at the path (a copy, or a new file renamed over the old one), which
/// changes at least the inode or the time, so a process can tell that the bundle it runs from
/// was replaced, and a new agent that checks its clients' code would refuse it.
struct ExecutableIdentity: Equatable {
  private let device: dev_t
  private let inode: ino_t
  private let size: off_t
  private let modified: timespec

  /// `nil` when nothing can be read at `file`.
  init?(of file: URL) {
    var info = stat()
    guard stat(file.path, &info) == 0 else { return nil }
    device = info.st_dev
    inode = info.st_ino
    size = info.st_size
    modified = info.st_mtimespec
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
      && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
  }
}

/// Which files are at a bundle's key paths, by `ExecutableIdentity`; a missing file counts too.
/// The executable alone is not enough: an update that changes only the agent or a resource
/// leaves it as it was, but changes the bundle's seal (`_CodeSignature/CodeResources`).
struct BundleFingerprint: Equatable {
  private let files: [ExecutableIdentity?]

  init(of files: [URL]) {
    self.files = files.map(ExecutableIdentity.init(of:))
  }
}
