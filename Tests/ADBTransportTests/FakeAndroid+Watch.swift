import Foundation

@testable import ADBTransport

/// What happens to a folder watch on the device.
enum WatchEvent: Equatable, Sendable {
  /// `inotifyd` started with its pid and its `<folder>:<mask>` arguments.
  case started(Int, [String])
  /// Its connection closed.
  case closed(Int)
  /// `kill <pid>` ended it.
  case killed(Int)
}

/// `sh -c 'echo $$; exec inotifyd - "$@"' sh <folder>:<mask>…`: prints its pid, exits if a
/// folder is missing (as inotifyd does), then sends the scripted events and exits or watches
/// until the client closes.
extension FakeAndroid {
  func inotifyd(_ words: [String], _ peer: Peer) async throws {
    let arguments = Array(words.dropFirst(4))
    let (pid, chunks, ends, missing, events) = state.withLock { state in
      let pid = state.tools.nextWatcher
      state.tools.nextWatcher += 1
      state.tools.watchers.insert(pid)
      let missing = arguments.contains { argument in
        let folder = argument.split(separator: ":").first.map(String.init) ?? argument
        guard case .folder = state.nodes[Self.bytes(folder)] else { return true }
        return false
      }
      return (pid, state.tools.inotify, state.tools.inotifyEnds, missing, state.tools.watchEvents)
    }
    events?.yield(.started(pid, arguments))
    defer { events?.yield(.closed(pid)) }
    try await peer.raw(Data("\(pid)\n".utf8))
    if missing {
      try await peer.raw(Data("inotifyd: No such file or directory\n".utf8))
      await peer.finish()
      return
    }
    for chunk in chunks { try await peer.raw(chunk) }
    if ends {
      await peer.finish()
    } else {
      _ = try? await peer.stream.read(exactly: 1)
    }
  }
}
