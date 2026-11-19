import FerryIPC
import Foundation

/// Open Shell: what Terminal is given to run `adb -s <serial> shell`.
///
/// Terminal opens a `.command` file and runs it; the file is written to a private folder (mode
/// 0700, named for this launch) with the one command in it, so there is one layer of quoting, for
/// zsh, over parts that were checked already (`ShellTarget` accepts only an absolute adb path
/// without control characters and a serial in adb's own alphabet). A script for Terminal's own
/// `do script` would need the command quoted for zsh and again for AppleScript, and the first use
/// asks the user for permission to control Terminal. Opening a file asks for neither.
///
/// The script removes itself and its folder before it runs adb, so nothing stays behind once
/// Terminal has started it; one Terminal never started is removed by `sweep` the next time.
enum ShellLaunch {
  static let folderPrefix = "ferry-shell-"
  static let fileName = "shell.command"

  /// Wraps `text` in single quotes for zsh; a `'` in it ends the quoting, is escaped, and
  /// starts it again.
  static func quoted(_ text: String) -> String {
    "'" + text.replacing("'", with: "'\\''") + "'"
  }

  static func script(for target: ShellTarget, file: URL) -> String {
    """
    #!/bin/zsh
    rm -f -- \(quoted(file.path))
    rmdir -- \(quoted(file.deletingLastPathComponent().path)) 2>/dev/null
    \(quoted(target.adb)) -s \(quoted(target.serial)) shell

    """
  }

  /// Writes the script into a new private folder under `base` and returns its URL.
  static func prepare(
    _ target: ShellTarget, in base: URL = FileManager.default.temporaryDirectory
  ) throws -> URL {
    let folder = base.appending(
      path: folderPrefix + UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = folder.appending(path: fileName)
    let written = FileManager.default.createFile(
      atPath: file.path, contents: Data(script(for: target, file: file).utf8),
      attributes: [.posixPermissions: 0o700])
    guard written else {
      remove(file)
      throw CocoaError(.fileWriteUnknown)
    }
    return file
  }

  /// Removes the script's folder.
  static func remove(_ file: URL) {
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
  }

  /// Removes the folders of launches more than `age` seconds old: a script Terminal never ran.
  /// Nothing else in `base` is touched.
  static func sweep(
    in base: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 3600
  ) {
    let manager = FileManager.default
    guard
      let names = try? manager.contentsOfDirectory(atPath: base.path)
    else { return }
    for name in names where name.hasPrefix(folderPrefix) {
      let folder = base.appending(path: name, directoryHint: .isDirectory)
      guard
        let modified = (try? manager.attributesOfItem(atPath: folder.path))?[.modificationDate]
          as? Date,
        -modified.timeIntervalSinceNow > age
      else { continue }
      try? manager.removeItem(at: folder)
    }
  }
}
