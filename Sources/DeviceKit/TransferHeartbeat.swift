import Synchronization

/// Signs of life from a transfer whose progress its caller does not otherwise see, such as the
/// copy a move makes on a device without MoveObject. The transfer arms it when it starts and
/// beats once a block; a watcher that sees no beat for a while knows the device has stopped
/// (see the agent's `StallWatch`). Work that never arms it, such as a native MoveObject, which
/// the device carries out in one call that reports nothing however long it takes, is never
/// judged by it.
public final class TransferHeartbeat: Sendable {
  /// The heartbeat of the request the current task is handling; `nil` when nothing watches.
  @TaskLocal public static var current: TransferHeartbeat?

  private let beats = Atomic<UInt64>(0)
  private let armed = Atomic<Bool>(false)

  public init() {}

  /// A transfer that beats per block has started: from now on, a stop in its beats is a stall.
  public func arm() {
    armed.store(true, ordering: .releasing)
  }

  public var isArmed: Bool {
    armed.load(ordering: .acquiring)
  }

  public func beat() {
    beats.add(1, ordering: .relaxed)
  }

  public var count: UInt64 {
    beats.load(ordering: .relaxed)
  }
}
