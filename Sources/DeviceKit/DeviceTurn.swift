/// A request's turn at the device: the moment a session's operation holds the session's gate,
/// which a transfer holds for its whole length, so it is where a request on any of the
/// device's storages really waits.
///
/// The agent sets `current` for each request: it drops a request its client cancelled while it
/// waited, and otherwise tells the client the request has started, so the client's reply
/// deadline measures device work, never queueing. Every session calls `take()` once it holds its
/// gate, before touching the device.
public protocol DeviceTurn: Sendable {
  /// Throws to drop the operation.
  func takeTurn() throws(TransportError)
  /// Whether the request's client has given up on it, so work it started stops at its next
  /// step.
  var isCancelled: Bool { get }
}

extension DeviceTurn {
  public var isCancelled: Bool { false }
}

public enum DeviceTurns {
  /// The turn of the request the current task is handling; `nil` outside one.
  @TaskLocal public static var current: (any DeviceTurn)?

  /// Called by a session once it holds its operation gate. Throws to drop the operation.
  public static func take() throws(TransportError) {
    try current?.takeTurn()
  }
}
