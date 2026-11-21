import DeviceKit
import Foundation
import Network
import Synchronization

/// Whether macOS denies this process the local network, which it does to the agent, and to the
/// adb server the agent starts, until the user allows Ferry in System Settings › Privacy &
/// Security › Local Network. There is no API that says so; a TCP connection to a local address
/// waits with `localNetworkDenied` instead (TN3179, "Check for local network access"). Asking
/// also raises the system's Local Network alert, under Ferry's name, while the choice is still
/// open.
public enum LocalNetworkAccess {
  /// Connects to `endpoint` and reports whether the connection waits on a denied Local Network
  /// permission. Anything else (connected, refused, unreachable, or no answer `within`) is not a
  /// denial. The connection is cancelled either way.
  public static func isDenied(_ endpoint: WirelessEndpoint, within limit: Duration = .seconds(2))
    async -> Bool
  {
    guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return false }
    let connection = NWConnection(
      host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
    let answer = Answer()
    let queue = DispatchQueue(label: "io.github.krisarmstrong.ferry.local-network")
    let denied = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        answer.wait(continuation)
        connection.stateUpdateHandler = { [weak connection] state in
          switch state {
          case .waiting:
            answer.give(connection?.currentPath?.unsatisfiedReason == .localNetworkDenied)
          case .ready, .failed, .cancelled:
            answer.give(false)
          default:
            break
          }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(limit / .milliseconds(1)))) {
          answer.give(false)
        }
      }
    } onCancel: {
      answer.give(false)
    }
    connection.cancel()
    return denied
  }

  /// The first answer wins; later ones (a cancel after a timeout) are dropped.
  private final class Answer: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Bool, Never>?, given: Bool?)>(
      (nil, nil))

    func wait(_ continuation: CheckedContinuation<Bool, Never>) {
      let given = state.withLock { state -> Bool? in
        if state.given == nil { state.continuation = continuation }
        return state.given
      }
      if let given { continuation.resume(returning: given) }
    }

    func give(_ value: Bool) {
      let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
        guard state.given == nil else { return nil }
        state.given = value
        defer { state.continuation = nil }
        return state.continuation
      }
      continuation?.resume(returning: value)
    }
  }
}
