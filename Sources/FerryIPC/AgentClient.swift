import DeviceKit
import Foundation
import os

/// Sends requests to the agent. A protocol so the extension's logic can run against a fake.
public protocol AgentSending: Sendable {
  /// `file` is sent as a descriptor: readable for `create` and `replaceContents`, writable for
  /// `fetch`, and `nil` for every other request. A transfer's progress, as the agent reports it,
  /// goes to `progress` while the request runs.
  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError) -> AgentResponse

  /// As above, for a request the agent answers with a stream of log lines: each batch goes to
  /// `logs` while the request runs. A conformer that does not stream ignores `logs`.
  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?,
    logs: LogBatchHandler?
  ) async throws(TransportError) -> AgentResponse
}

extension AgentSending {
  public func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?,
    logs: LogBatchHandler?
  ) async throws(TransportError) -> AgentResponse {
    try await send(request, file: file, progress: progress)
  }

  /// Sends a request whose progress nobody follows.
  public func send(_ request: AgentRequest, file: FileHandle?) async throws(TransportError)
    -> AgentResponse
  {
    try await send(request, file: file, progress: nil)
  }
}

/// An XPC client of the agent.
///
/// launchd may relaunch the agent at any time, so a lost connection is replaced on the next
/// `send`. Calls in flight when it is lost throw `.deviceDisconnected`; the agent's own
/// failures come back as `.failure` responses.
///
/// A cancelled call throws `.cancelled` at once. The agent is not told: it finishes the request,
/// and its reply is dropped. A fetch it is still writing goes into the caller's descriptor,
/// which the caller has closed and removed by then.
public actor AgentClient: AgentSending {
  private enum Target {
    case machService(String, requirement: String)
    case endpoint(NSXPCListenerEndpoint)
  }

  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "AgentClient")

  private let target: Target
  private var connection: NSXPCConnection?
  /// The progress handler of each request in flight, by the identifier it was sent under.
  private var progressHandlers: [String: TransferProgressHandler] = [:]
  /// The handlers of requests that take log lines.
  private let logRouter = LogRouter()
  /// The agent's progress reports, from every connection, in the order they arrived.
  private let progressEvents: AsyncStream<ProgressReceiver.Event>
  private let progressSink: AsyncStream<ProgressReceiver.Event>.Continuation
  /// Exported on every connection to the agent.
  private let receiver: ProgressReceiver
  private var progressPump: Task<Void, Never>?
  /// The number of the last report handed on, and the requests waiting for a later one.
  private var delivered: UInt64 = 0
  private var catchUpWaiters: [(sequence: UInt64, waiter: CheckedContinuation<Void, Never>)] = []

  /// Connects to the agent of `identity`'s team, which must be signed by that team.
  public init(identity: FerryIdentity) {
    self.init(
      target: .machService(identity.machServiceName, requirement: identity.agentRequirement))
  }

  /// Connects to an anonymous listener in the same process, without checking its signature.
  init(endpoint: NSXPCListenerEndpoint) {
    self.init(target: .endpoint(endpoint))
  }

  private init(target: Target) {
    self.target = target
    (progressEvents, progressSink) = AsyncStream.makeStream(of: ProgressReceiver.Event.self)
    receiver = ProgressReceiver(progressSink, logs: logRouter)
  }

  deinit {
    progressSink.finish()
  }

  public func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError) -> AgentResponse {
    try await send(request, file: file, progress: progress, logs: nil)
  }

  public func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?,
    logs: LogBatchHandler?
  ) async throws(TransportError) -> AgentResponse {
    let id = UUID().uuidString
    if let progress { progressHandlers[id] = progress }
    if let logs { logRouter.set(id, logs) }
    defer {
      progressHandlers[id] = nil
      logRouter.remove(id)
    }
    let data: Data
    do {
      data = try JSONEncoder().encode(request)
    } catch {
      throw .io("cannot encode request: \(error.localizedDescription)")
    }
    if Task.isCancelled { throw .cancelled }
    let connection = currentConnection()
    let reply = await awaitReply { reply, failed in
      guard let proxy = connection.remoteObjectProxyWithErrorHandler(failed) as? any AgentXPC
      else {
        failed(TransportError.io("agent proxy has the wrong interface"))
        return
      }
      proxy.send(data, id: id, file: file, reply: reply)
    }
    let replyData: Data
    switch reply {
    case .success(let data):
      replyData = data
      if progress != nil { await catchUp() }
    case .failure(is CancellationError):
      throw .cancelled
    case .failure(let error):
      // An interrupted connection stays usable: launchd relaunches the agent on the next
      // message. An invalid one never recovers, so the next send must open a fresh one.
      if (error as NSError).code == NSXPCConnectionInvalid {
        dropConnection(ObjectIdentifier(connection))
      }
      throw .deviceDisconnected
    }
    do {
      return try JSONDecoder().decode(AgentResponse.self, from: replyData)
    } catch {
      Self.log.error("undecodable reply from agent: \(error, privacy: .private)")
      throw .io("bad response from agent")
    }
  }

  private func currentConnection() -> NSXPCConnection {
    if let connection { return connection }
    let made: NSXPCConnection
    switch target {
    case .machService(let name, let requirement):
      made = NSXPCConnection(machServiceName: name)
      // Any same-user process can register this name in the gui domain first, so only a
      // Ferry-signed agent may answer.
      made.setCodeSigningRequirement(requirement)
    case .endpoint(let endpoint):
      made = NSXPCConnection(listenerEndpoint: endpoint)
    }
    made.remoteObjectInterface = NSXPCInterface(with: AgentXPC.self)
    made.exportedInterface = NSXPCInterface(with: AgentClientXPC.self)
    made.exportedObject = receiver
    startProgressPump()
    let id = ObjectIdentifier(made)
    made.invalidationHandler = { [weak self] in
      Task { await self?.dropConnection(id) }
    }
    made.resume()
    connection = made
    return made
  }

  /// Hands the agent's progress reports to their requests' handlers, in order. A report for a
  /// request that has already returned is dropped.
  private func startProgressPump() {
    guard progressPump == nil else { return }
    progressPump = Task { [weak self, progressEvents] in
      for await event in progressEvents {
        await self?.deliver(event)
      }
    }
  }

  private func deliver(_ event: ProgressReceiver.Event) {
    progressHandlers[event.request]?(event.completed, event.total)
    delivered = event.sequence
    let (ready, waiting) = catchUpWaiters.partitioned { $0.sequence <= delivered }
    catchUpWaiters = waiting
    for entry in ready { entry.waiter.resume() }
  }

  /// Returns once every report received so far is handed on. XPC runs a reply after the
  /// messages that came before it, so after a reply this delivers the request's last report.
  private func catchUp() async {
    let target = receiver.received
    guard delivered < target else { return }
    await withCheckedContinuation { catchUpWaiters.append((target, $0)) }
  }

  private func dropConnection(_ id: ObjectIdentifier) {
    guard let connection, ObjectIdentifier(connection) == id else { return }
    Self.log.info("connection to agent invalidated")
    self.connection = nil
  }
}

extension Array {
  /// The elements that match, then the rest, each in order.
  fileprivate func partitioned(_ matches: (Element) -> Bool) -> ([Element], [Element]) {
    (filter(matches), filter { !matches($0) })
  }
}
