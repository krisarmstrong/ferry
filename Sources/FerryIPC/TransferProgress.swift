import DeviceKit
import Foundation
import Synchronization

/// Bytes of one transfer moved so far, and its total.
public typealias TransferProgressHandler = @Sendable (_ completed: UInt64, _ total: UInt64) -> Void

/// The interface a client exports on its connection to the agent: the agent reports a transfer's
/// progress on it while the request runs, at most a few times a second. A cancel goes the other
/// way, keyed by the same request identifier (`AgentXPC.cancel(_:)`).
///
/// `Sendable`: an XPC proxy may be messaged from any thread.
@objc public protocol AgentClientXPC: Sendable {
  /// `request` is the identifier the client sent the request under.
  func progress(_ request: String, completed: UInt64, total: UInt64)
  /// Answered once every report sent before it has been received. The agent sends it before
  /// replying to a request that reported progress, so its reports never trail the reply.
  func flush(_ request: String, reply: @escaping @Sendable () -> Void)
  /// The request `request` has its turn at the device: its reply deadline starts now (see
  /// `RequestCancellation.markStarted()`).
  func started(_ request: String)
  /// A batch of log lines (a JSON `LogBatch`) for the request `request`. The client answers once
  /// it has taken the batch, which is when the agent sends the next one: `true` to go on, `false`
  /// when the client has nothing waiting for lines (its request ended), which ends the stream.
  func logBatch(_ request: String, batch: Data, reply: @escaping @Sendable (Bool) -> Void)
}

/// The handlers of the requests in flight that take log lines, by request identifier.
final class LogRouter: Sendable {
  private let handlers = Mutex<[String: LogBatchHandler]>([:])

  func set(_ request: String, _ handler: @escaping LogBatchHandler) {
    handlers.withLock { $0[request] = handler }
  }

  func remove(_ request: String) {
    handlers.withLock { $0[request] = nil }
  }

  /// Hands the batch to the request's handler and returns once it has taken it. `false` if no
  /// request waits for lines; a batch that does not decode is dropped.
  func deliver(_ request: String, _ data: Data) async -> Bool {
    guard let handler = handlers.withLock({ $0[request] }) else { return false }
    if let batch = try? JSONDecoder().decode(LogBatch.self, from: data) {
      await handler(batch)
    }
    return true
  }
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

  /// Whole percent done, 0 until the total is known, 0...100 whatever the device reports. The
  /// product is taken at double width, so a device-reported size near `UInt64.max` cannot
  /// overflow it.
  public var percent: Int {
    guard total > 0 else { return 0 }
    let product = min(completed, total).multipliedFullWidth(by: 100)
    return Int(total.dividingFullWidth(product).quotient)
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
  private let logs: LogRouter
  /// The reply deadline of each request in flight that has one.
  let deadlines = Mutex<[String: ReplyDeadline]>([:])

  init(_ events: AsyncStream<Event>.Continuation, logs: LogRouter) {
    self.events = events
    self.logs = logs
  }

  func started(_ request: String) {
    deadlines.withLock { $0[request] }?.start()
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

  func logBatch(_ request: String, batch: Data, reply: @escaping @Sendable (Bool) -> Void) {
    let logs = logs
    Task { reply(await logs.deliver(request, batch)) }
  }
}

/// Whether a request reported any progress, set from the device's queue.
final class Reported: Sendable {
  private let flag = Atomic(false)
  var any: Bool { flag.load(ordering: .acquiring) }
  func mark() { flag.store(true, ordering: .releasing) }
}
