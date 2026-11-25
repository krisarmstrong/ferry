import Synchronization

/// Signs of life from a transfer whose progress its caller does not otherwise see, such as the
/// copy a move makes on a device without MoveObject. The transfer beats once a block; a watcher
/// that sees no beat for a while knows the device has stopped (see the agent's `StallWatch`).
public final class TransferHeartbeat: Sendable {
  /// The heartbeat of the request the current task is handling; `nil` when nothing watches.
  @TaskLocal public static var current: TransferHeartbeat?

  private let beats = Atomic<UInt64>(0)

  public init() {}

  public func beat() {
    beats.add(1, ordering: .relaxed)
  }

  public var count: UInt64 {
    beats.load(ordering: .relaxed)
  }
}
