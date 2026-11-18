import Foundation

/// Temporary files for tests: every one under a single folder for the test process, which is
/// removed when the process exits (and, if it crashed, by the next test process), and watched so
/// that the tests cannot keep more than `limit` bytes of real data in it. The guard covers only
/// what is written under `root`: tests point every scratch location there, the agent's included
/// (see `AgentHarness`).
///
/// Tests that need a huge file make it sparse (`FileHandle.truncate(atOffset:)`), which takes no
/// space. A test that starts copying such a file for real stops the whole test process at
/// `limit`, rather than filling the disk.
public enum TestScratch {
  /// The most real data the test process may keep under `root` at once.
  public static let limit: UInt64 = 64 << 20

  private static let prefix = "ferry-tests-"

  /// The test process's folder. Created, with its watchdog, on first use.
  public static let root: URL = makeRoot()

  /// A new empty folder under `root`.
  public static func folder(_ label: String = "scratch") throws -> URL {
    let url = root.appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// The bytes the files under `url` take on disk: a sparse file counts only what was written.
  public static func allocatedBytes(at url: URL) -> UInt64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard
      let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
    else { return 0 }
    var total: UInt64 = 0
    for case let file as URL in walker {
      let values = try? file.resourceValues(forKeys: Set(keys))
      guard values?.isRegularFile == true else { continue }
      total += UInt64(values?.totalFileAllocatedSize ?? 0)
    }
    return total
  }

  private static func makeRoot() -> URL {
    let temporary = FileManager.default.temporaryDirectory
    sweepRootsOfFinishedProcesses(in: temporary)
    let url = temporary.appending(path: prefix + String(getpid()), directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      fatalError("cannot make the test scratch folder: \(error)")
    }
    atexit {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "ferry-tests-\(getpid())", directoryHint: .isDirectory)
      try? FileManager.default.removeItem(at: root)
    }
    watch(url)
    return url
  }

  /// Stops the test process once `root` holds more than `limit` bytes.
  private static func watch(_ root: URL) {
    Task.detached(priority: .utility) {
      while true {
        let used = allocatedBytes(at: root)
        if used > limit {
          fatalError("tests wrote \(used) bytes under \(root.path), over the \(limit)-byte limit")
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  /// Removes the folders of test processes that are no longer running, such as one that
  /// crashed before it could remove its own.
  private static func sweepRootsOfFinishedProcesses(in temporary: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
    for name in names where name.hasPrefix(prefix) {
      guard let pid = pid_t(name.dropFirst(prefix.count)), kill(pid, 0) != 0, errno == ESRCH
      else { continue }
      try? FileManager.default.removeItem(at: temporary.appending(path: name))
    }
  }
}
