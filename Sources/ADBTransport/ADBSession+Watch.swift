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

  /// Watches `folders` with the device's `inotifyd -`, which prints `<event>\t<folder>[\t<name>]`
  /// for each event, on one `exec:` connection of the session's route. inotifyd reads its
  /// arguments as `<path>:<mask>` and exits if any folder is missing, so a folder whose path has
  /// a `:`, or a tab or newline that would break its lines, is left to the periodic listing.
  public func watch(_ folders: [FolderHint]) async -> AsyncStream<FolderHint>? {
    var watched: [String: FolderHint] = [:]
    for hint in folders where hint.storage.device == info.id {
      guard let root = ADBStorages.root(forKey: hint.storage.key) else { continue }
      let path = ([root] + hint.folder.components).joined(separator: "/")
      guard !path.contains(where: { $0 == ":" || $0 == "\t" || $0 == "\n" || $0 == "\r" })
      else { continue }
      watched[path] = hint
    }
    guard !disconnected, !watched.isEmpty else { return nil }
    let stream: ADBStream
    do throws(ADBError) {
      let arguments = ["-"] + watched.keys.sorted().map { "\($0):\(Self.watchMask)" }
      stream = try await host.connect(
        route, service: "exec:" + (try ADBShell.command("inotifyd", arguments)))
    } catch {
      Self.log.info("watching folders: \(String(describing: error), privacy: .private)")
      return nil
    }
    guard !disconnected else {
      stream.cancel()
      return nil
    }
    let connections = watches
    let paths = watched
    connections.add(stream)
    return AsyncStream { continuation in
      let reader = Task.detached {
        var lines = ADBLogLines()
        do throws(ADBError) {
          while let chunk = try await stream.readSome(upTo: 4096) {
            for line in lines.append(chunk) {
              if let hint = Self.hint(in: line, paths) { continuation.yield(hint) }
            }
          }
        } catch {
          Self.log.info("folder watch ended: \(String(describing: error), privacy: .private)")
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in
        reader.cancel()
        stream.cancel()
        connections.remove(stream)
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
