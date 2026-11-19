import DeviceKit
import Foundation
import os

/// Watches a recording's pull: it stops one larger than any real recording or than the Mac has
/// room for, and says when data has stopped arriving.
///
/// `screenrecord` defaults to 20 Mbit/s at 720p and the 180 s limit, about 450 MB; at 1080p it
/// stays under 1 GB. A device that sends more is broken or hostile, so 1 GiB is the cap.
final class PullWatch: Sendable {
  enum Stop {
    case tooLarge
    case noRoom(TransportError)
    case stalled
  }

  private struct State {
    var last = ContinuousClock.now
    var stop: Stop?
    var checkedRoom = false
  }

  private let limit: UInt64
  private let folder: URL
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(limit: UInt64, folder: URL) {
    self.limit = limit
    self.folder = folder
  }

  /// Why the pull was stopped, if it was.
  var stop: Stop? { state.withLock { $0.stop } }

  /// The pull's progress handler: false stops it.
  var progress: ProgressHandler {
    { [self] done, total in
      let checkRoom = state.withLock { state in
        state.last = .now
        defer { state.checkedRoom = true }
        return !state.checkedRoom
      }
      guard done <= limit, total <= limit else {
        state.withLock { $0.stop = .tooLarge }
        return false
      }
      if checkRoom {
        do throws(TransportError) {
          try LocalFile.requireSpace(total, at: folder)
        } catch {
          state.withLock { $0.stop = .noRoom(error) }
          return false
        }
      }
      return true
    }
  }

  /// True, once, when nothing has arrived for `limit`; the pull is then stopped as stalled.
  func idle(longerThan limit: Duration) -> Bool {
    state.withLock { state in
      guard state.stop == nil, state.last.duration(to: .now) > limit else { return false }
      state.stop = .stalled
      return true
    }
  }
}
