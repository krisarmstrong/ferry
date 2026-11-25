import DeviceKitTestSupport
import Foundation
import Network

@testable import ADBTransport

extension ADBHost {
  /// A host for a fake server, or for none with `refusing`: it starts no server of its own.
  init(port: UInt16, locator: ADBLocator, opener: @escaping Opener = socketOpener) {
    self.init(port: port, locator: locator, launcher: { _ in }, backoff: Backoff(), opener: opener)
  }

  /// Stands in for `ADBStream.open` where no server listens: every attempt is refused, through
  /// `ADBStream.connect` as a real one is, with its states scripted. A real connect to a closed
  /// loopback port is not refused promptly on every machine (CI runners have taken 5 to 10 s,
  /// and then timed out), so no test makes one; `ADBStreamOpenTests` covers how states decide.
  static let refusing: Opener = { _ throws(ADBError) in
    // The deadline is on a clock nothing moves: a refusal decides, never the time.
    let clock = ManualClock()
    try await ADBStream.connect(until: clock.now.advanced(by: .seconds(10)), on: clock) {
      ADBStream.Attempt(
        value: (),
        states: AsyncStream {
          $0.yield(.preparing)
          $0.yield(.waiting(.posix(.ECONNREFUSED)))
        },
        start: {}, cancel: {})
    }
    preconditionFailure("a refused attempt is never ready")
  }
}
