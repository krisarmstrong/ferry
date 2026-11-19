import DeviceKit
import Foundation
import Synchronization

/// The connections of a session's folder watches, so the session closes them when it ends.
final class WatchConnections: Sendable {
  private let streams = Mutex<[ObjectIdentifier: ADBStream]>([:])

  func add(_ stream: ADBStream) {
    streams.withLock { $0[ObjectIdentifier(stream)] = stream }
  }

  func remove(_ stream: ADBStream) {
    _ = streams.withLock { $0.removeValue(forKey: ObjectIdentifier(stream)) }
  }

  func closeAll() {
    let open = streams.withLock { streams in
      defer { streams = [:] }
      return Array(streams.values)
    }
    for stream in open { stream.cancel() }
  }
}

extension ADBSession {
  /// The events `inotifyd` reports: created, closed after writing, deleted, and the folder itself
  /// deleted or moved: the mask the Android 8.1 units accepted. Shared storage reports them
  /// incompletely (a unit printed only the delete of a touch, move and remove), so any of them
  /// is a hint, and the periodic listing finds what none reports.
  static let watchMask = "nwdDM"
  /// Runs `inotifyd` as the process whose pid it prints first, as the recording does, so the
  /// watch can kill exactly it when it stops: whether adbd ends an `exec:` child when its socket
  /// closes is not known for every device, and every new watch starts another.
  static let watchScript = "echo $$; exec inotifyd - \"$@\""
  /// How long the watch waits for the pid, and for the kill when it stops.
  static let watchAnswerLimit = Duration.seconds(10)

  /// Watches `folders` with the device's `inotifyd -`, which prints `<event>\t<folder>[\t<name>]`
  /// for each event, on one `exec:` connection of the session's route. inotifyd reads its
  /// arguments as `<path>:<mask>` and exits if any folder is missing, so a folder whose path has
  /// a `:`, or a tab or newline that would break its lines, is left to the periodic listing.
  /// When the stream ends, for any reason, the process is killed by its pid.
  public func watch(_ folders: [FolderHint]) async -> AsyncStream<FolderHint>? {
    var found: [String: FolderHint] = [:]
    for hint in folders where hint.storage.device == info.id {
      guard let root = ADBStorages.root(forKey: hint.storage.key) else { continue }
      let path = ([root] + hint.folder.components).joined(separator: "/")
      guard !path.contains(where: { $0 == ":" || $0 == "\t" || $0 == "\n" || $0 == "\r" })
      else { continue }
      found[path] = hint
    }
    let watched = found
    guard !disconnected, !watched.isEmpty else { return nil }
    let process: WatchProcess
    do throws(ADBError) {
      process = try await startWatcher(watched.keys.sorted())
    } catch {
      Self.log.info("watching folders: \(String(describing: error), privacy: .private)")
      return nil
    }
    guard !disconnected else {
      process.stream.cancel()
      Self.kill(process.pid, host: host, route: route)
      return nil
    }
    return events(of: process, watched)
  }

  /// Starts the script over `exec:` and reads the pid it prints first.
  private func startWatcher(_ paths: [String]) async throws(ADBError) -> WatchProcess {
    let arguments = paths.map { "\($0):\(Self.watchMask)" }
    let stream = try await host.connect(
      route,
      service: "exec:" + (try ADBShell.command("sh", ["-c", Self.watchScript, "sh"] + arguments)))
    do throws(ADBError) {
      return try await Self.readPID(stream)
    } catch {
      stream.cancel()
      throw error
    }
  }

  /// The hints in what the watcher prints. However the stream ends, the connection closes and
  /// the process is killed.
  private func events(of process: WatchProcess, _ watched: [String: FolderHint])
    -> AsyncStream<FolderHint>
  {
    let (host, route, connections, stream, pid) = (
      host, route, watches, process.stream, process.pid
    )
    connections.add(stream)
    let (events, continuation) = AsyncStream.makeStream(of: FolderHint.self)
    let reader = ReaderHandle()
    // Set before the reader starts, so an inotifyd that exits at once still cleans up.
    continuation.onTermination = { _ in
      reader.cancel()
      stream.cancel()
      connections.remove(stream)
      Self.kill(pid, host: host, route: route)
    }
    for line in process.early {
      if let hint = Self.hint(in: line, watched) { continuation.yield(hint) }
    }
    let carried = process.lines
    reader.start {
      var lines = carried
      do throws(ADBError) {
        while let chunk = try await stream.readSome(upTo: 4096) {
          for line in lines.append(chunk) {
            if let hint = Self.hint(in: line, watched) { continuation.yield(hint) }
          }
        }
      } catch {
        Self.log.info("folder watch ended: \(String(describing: error), privacy: .private)")
      }
      continuation.finish()
    }
    return events
  }

  /// The pid the script prints first, the lines that came with it, and the start of a line
  /// that has not ended yet.
  private static func readPID(_ stream: ADBStream) async throws(ADBError) -> WatchProcess {
    try await ADBTransport.within(watchAnswerLimit) { () async throws(ADBError) in
      var lines = ADBLogLines()
      while let chunk = try await stream.readSome(upTo: 4096) {
        var found = lines.append(chunk)
        guard !found.isEmpty else { continue }
        let line = String(bytes: found.removeFirst(), encoding: .utf8) ?? ""
        // Digits only, and never 0 or 1: `kill` would read them as the group or init.
        guard (1...10).contains(line.count), line.allSatisfy({ $0.isASCII && $0.isNumber }),
          let number = Int(line), number >= 2
        else { throw .failed("inotifyd did not start: \(line.prefix(200))") }
        return WatchProcess(stream: stream, pid: line, early: found, lines: lines)
      }
      throw .failed("inotifyd did not start")
    }
  }

  /// Kills the watch's inotifyd, on a task of its own and bounded; a device that has gone took
  /// the process with it.
  private static func kill(_ pid: String, host: ADBHost, route: ADBRoute) {
    Task.detached {
      do throws(ADBError) {
        let command = try ADBShell.command("kill", [pid])
        _ = try await ADBTransport.within(watchAnswerLimit) { () async throws(ADBError) in
          try await host.run(route: route, command: command)
        }
      } catch {
        ADBSession.log.info(
          "stopping a folder watch: \(String(describing: error), privacy: .private)")
      }
    }
  }

  /// The watched folder an `inotifyd -` line names: a one-letter event, a tab, the folder as
  /// it was given, then a tab and a name or nothing.
  static func hint(in line: Data, _ watched: [String: FolderHint]) -> FolderHint? {
    let fields = line.split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false)
    guard fields.count >= 2, fields[0].count == 1,
      let path = String(bytes: fields[1], encoding: .utf8)
    else { return nil }
    return watched[path]
  }
}

/// A watcher just started: its connection, its pid, the lines that came with the pid, and the
/// start of a line that has not ended yet.
private struct WatchProcess: Sendable {
  let stream: ADBStream
  let pid: String
  let early: [Data]
  let lines: ADBLogLines
}

/// The task reading a watch, which its stream's clean-up, set before the task exists, cancels.
private final class ReaderHandle: Sendable {
  private let task = Mutex<Task<Void, Never>?>(nil)
  private let cancelled = Mutex(false)

  func start(_ body: @escaping @Sendable () async -> Void) {
    let started = Task.detached(operation: body)
    let stop = task.withLock { task in
      task = started
      return cancelled.withLock { $0 }
    }
    if stop { started.cancel() }
  }

  func cancel() {
    cancelled.withLock { $0 = true }
    task.withLock { $0 }?.cancel()
  }
}
