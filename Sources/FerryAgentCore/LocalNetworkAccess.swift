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
  /// What the agent's own connection to an address found.
  public enum Reach: Sendable, Equatable {
    /// macOS denies the agent the local network.
    case denied
    /// The address accepted the connection.
    case reached
    /// Refused, unreachable, or no answer in time.
    case unknown
  }

  /// `reach` as `WirelessADB` asks it; tests fake it.
  public typealias Check = @Sendable (WirelessEndpoint) async -> Reach

  /// Connects to `endpoint` and reports whether the connection waits on a denied Local Network
  /// permission, or was accepted. The connection is cancelled either way.
  public static func reach(_ endpoint: WirelessEndpoint, within limit: Duration = .seconds(2))
    async -> Reach
  {
    guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return .unknown }
    let connection = NWConnection(
      host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
    let answer = Answer()
    let queue = DispatchQueue(label: "io.github.krisarmstrong.ferry.local-network")
    let reach = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Reach, Never>) in
        answer.wait(continuation)
        connection.stateUpdateHandler = { [weak connection] state in
          switch state {
          case .waiting:
            let denied = connection?.currentPath?.unsatisfiedReason == .localNetworkDenied
            answer.give(denied ? .denied : .unknown)
          case .ready:
            answer.give(.reached)
          case .failed, .cancelled:
            answer.give(.unknown)
          default:
            break
          }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(limit / .milliseconds(1)))) {
          answer.give(.unknown)
        }
      }
    } onCancel: {
      answer.give(.unknown)
    }
    connection.cancel()
    return reach
  }

  /// The first answer wins; later ones (a cancel after a timeout) are dropped.
  private final class Answer: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Reach, Never>?, given: Reach?)>(
      (nil, nil))

    func wait(_ continuation: CheckedContinuation<Reach, Never>) {
      let given = state.withLock { state -> Reach? in
        if state.given == nil { state.continuation = continuation }
        return state.given
      }
      if let given { continuation.resume(returning: given) }
    }

    func give(_ value: Reach) {
      let continuation = state.withLock { state -> CheckedContinuation<Reach, Never>? in
        guard state.given == nil else { return nil }
        state.given = value
        defer { state.continuation = nil }
        return state.continuation
      }
      continuation?.resume(returning: value)
    }
  }
}
