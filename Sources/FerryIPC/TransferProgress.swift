import DeviceKit
import Foundation
import Synchronization

/// Bytes of one transfer moved so far, and its total.
public typealias TransferProgressHandler = @Sendable (_ completed: UInt64, _ total: UInt64) -> Void

/// The interface a client exports on its connection to the agent: the agent reports a transfer's
/// progress on it while the request runs, at most a few times a second. Only progress travels
/// this way now; a cancel can join it as a call in the other direction, keyed by the same
/// request identifier.
///
/// `Sendable`: an XPC proxy may be messaged from any thread.
@objc public protocol AgentClientXPC: Sendable {
  /// `request` is the identifier the client sent the request under.
  func progress(_ request: String, completed: UInt64, total: UInt64)
  /// Answered once every report sent before it has been received. The agent sends it before
  /// replying to a request that reported progress, so its reports never trail the reply.
  func flush(_ request: String, reply: @escaping @Sendable () -> Void)
}

/// A transfer the agent is running, for the menu.
public struct ActiveTransfer: Codable, Sendable, Equatable {
  public enum Direction: String, Codable, Sendable {
    /// From the Mac to the device.
    case toDevice
    /// From the device to the Mac.
    case toMac
  }

  public let device: DeviceID
  /// The item's name, which the device or the user chose.
  public let name: String
  public let direction: Direction
  public let completed: UInt64
  public let total: UInt64

  public init(
    device: DeviceID, name: String, direction: Direction, completed: UInt64, total: UInt64
  ) {
    self.device = device
    self.name = name
    self.direction = direction
    self.completed = completed
    self.total = total
  }

  /// Whole percent done, 0 until the total is known.
  public var percent: Int {
    guard total > 0 else { return 0 }
    return Int(min(completed, total) * 100 / total)
  }
}

/// Receives the agent's progress reports on the client's connections and hands them on in
/// order, numbered, so a client can wait until it has delivered every report that arrived before
/// a reply.
final class ProgressReceiver: NSObject, AgentClientXPC {
  struct Event: Sendable {
    let sequence: UInt64
    let request: String
    let completed: UInt64
    let total: UInt64
  }

  private let events: AsyncStream<Event>.Continuation
  private let count = Atomic<UInt64>(0)

  init(_ events: AsyncStream<Event>.Continuation) {
    self.events = events
  }

  /// The number of the last report received.
  var received: UInt64 { count.load(ordering: .acquiring) }

  func progress(_ request: String, completed: UInt64, total: UInt64) {
    let sequence = count.add(1, ordering: .acquiringAndReleasing).newValue
    events.yield(
      Event(sequence: sequence, request: request, completed: completed, total: total))
  }

  /// XPC delivers a connection's messages in order, so the reports before this one are in.
  func flush(_ request: String, reply: @escaping @Sendable () -> Void) {
    reply()
  }
}

/// Whether a request reported any progress, set from the device's queue.
final class Reported: Sendable {
  private let flag = Atomic(false)
  var any: Bool { flag.load(ordering: .acquiring) }
  func mark() { flag.store(true, ordering: .releasing) }
}
