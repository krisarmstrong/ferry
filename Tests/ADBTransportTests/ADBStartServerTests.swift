import Foundation
import Testing

@testable import ADBTransport

/// `adb start-server` waits for the server to come up; a cancelled caller must not wait with it.
/// A shell script stands in for adb, so no real adb ever runs.
struct ADBStartServerTests {
  /// A script that records its PID in `pidFile` and then sleeps, as a slow `adb start-server`.
  static func slowAdb() throws -> (adb: URL, pidFile: URL) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ferry-adb-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let adb = folder.appending(path: "adb")
    let pidFile = folder.appending(path: "pid")
    try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".utf8).write(to: adb)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
    return (adb, pidFile)
  }

  /// The error `body` threw, or `nil`.
  static func outcome(_ body: () async throws(ADBError) -> Void) async -> ADBError? {
    do throws(ADBError) {
      try await body()
      return nil
    } catch {
      return error
    }
  }

  /// The PID the script wrote, once it has written all of it.
  static func recordedPID(_ file: URL) -> pid_t? {
    guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n") else {
      return nil
    }
    return pid_t(text.dropLast())
  }

  static func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

  @Test func cancellingStopsWaitingAndEndsAdb() async throws {
    let (adb, pidFile) = try Self.slowAdb()
    defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
    let started = ContinuousClock.now
    let task = Task {
      await Self.outcome { () async throws(ADBError) in
        try await ADBHost.startServer(adb: adb, port: 5037)
      }
    }
    var recorded: pid_t?
    #expect(
      try await eventually {
        recorded = Self.recordedPID(pidFile)
        return recorded != nil
      })
    let pid = try #require(recorded)
    task.cancel()
    #expect(await task.value == .cancelled)
    #expect(started.duration(to: .now) < .seconds(20))
    #expect(try await eventually { !Self.isRunning(pid) })
  }

  @Test func anAlreadyCancelledCallerNeverLaunchesAdb() async throws {
    let (adb, pidFile) = try Self.slowAdb()
    defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
    let task = Task {
      while !Task.isCancelled { await Task.yield() }
      return await Self.outcome { () async throws(ADBError) in
        try await ADBHost.startServer(adb: adb, port: 5037)
      }
    }
    task.cancel()
    #expect(await task.value == .cancelled)
    try await Task.sleep(for: .milliseconds(200))
    #expect(!FileManager.default.fileExists(atPath: pidFile.path))
  }
}
