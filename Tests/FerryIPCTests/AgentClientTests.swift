import DeviceKit
import Foundation
import Synchronization
import Testing

@testable import FerryIPC

/// The team the signed-only listener in these tests admits; no test peer is signed by it.
private let testIdentity = FerryIdentity(teamID: "X6JWYP43HG")!

private let listedID = ItemID.random()

private func listing() throws(TransportError) -> [ProviderEntry] {
  [
    ProviderEntry(
      id: listedID, parent: .root,
      item: RemoteItem(
        path: try RemotePath("/DCIM/a.jpg"), kind: .file, size: 3,
        modified: Date(timeIntervalSince1970: 1_700_000_000)))
  ]
}

/// Answers `.list` with `listing()`, writes `fetched` into the file sent with `.fetch`, and
/// parks `.status` until the test releases it.
private struct StubHandler: AgentHandling {
  let started: AsyncStream<Void>.Continuation
  let release: AsyncStream<Void>

  func handle(
    _ request: AgentRequest, file: FileHandle?, progress: @escaping TransferProgressHandler
  ) async -> AgentResponse {
    switch request {
    case .fetch:
      guard let file else { return .failure(.io("no file")) }
      progress(3, UInt64(fetched.count))
      progress(UInt64(fetched.count), UInt64(fetched.count))
      do {
        try file.write(contentsOf: fetched)
        return .done
      } catch {
        return .failure(.io(error.localizedDescription))
      }
    case .list:
      do {
        return .entries(try listing())
      } catch {
        return .failure(error)
      }
    case .status:
      started.yield()
      for await _ in release {}
      return .status(StatusReport(devices: [], provider: .disabled))
    default:
      return .failure(.unsupported("\(request)"))
    }
  }
}

/// Refuses the first `refusals` connections, as an agent that is restarting would, then hands
/// the rest to the real delegate.
private final class RefusingDelegate: NSObject, NSXPCListenerDelegate, Sendable {
  let inner: AgentListenerDelegate
  let refusals: Int
  let seen = Atomic(0)

  init(inner: AgentListenerDelegate, refusals: Int) {
    self.inner = inner
    self.refusals = refusals
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    guard seen.add(1, ordering: .relaxed).oldValue >= refusals else { return false }
    return inner.listener(listener, shouldAcceptNewConnection: connection)
  }
}

/// An anonymous listener serving `StubHandler`, and a client connected to it.
private struct Harness {
  let listener = NSXPCListener.anonymous()
  // The listener does not retain its delegate.
  let delegate: RefusingDelegate
  let client: AgentClient
  let started: AsyncStream<Void>
  let release: AsyncStream<Void>.Continuation

  /// `signedOnly` uses the production delegate, which admits only Ferry-signed peers.
  init(signedOnly: Bool = false, refusals: Int = 0) {
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let (releaseStream, release) = AsyncStream.makeStream(of: Void.self)
    let handler = StubHandler(started: startedContinuation, release: releaseStream)
    delegate = RefusingDelegate(
      inner: signedOnly
        ? AgentListenerDelegate(handler: handler, identity: testIdentity)
        : AgentListenerDelegate(handler: handler, codeSigningRequirement: nil),
      refusals: refusals)
    listener.delegate = delegate
    listener.resume()
    client = AgentClient(endpoint: listener.endpoint)
    self.started = started
    self.release = release
  }

  func finish() {
    release.finish()
    listener.invalidate()
  }
}

private let fetched = Data("fetched".utf8)

@Test(.timeLimit(.minutes(1)))
func fileDescriptorCrossesConnection() async throws {
  let harness = Harness()
  defer { harness.finish() }
  let target = FileManager.default.temporaryDirectory.appending(
    path: "ferry-ipc-\(UUID().uuidString)")
  try Data().write(to: target)
  defer { try? FileManager.default.removeItem(at: target) }
  let handle = try FileHandle(forWritingTo: target)
  defer { try? handle.close() }

  let response = try await harness.client.send(
    .fetch(domain: "d", id: listedID), file: handle)

  #expect(response == .done)
  #expect(try Data(contentsOf: target) == fetched)
}

@Test(.timeLimit(.minutes(1)))
func clientServerOverAnonymousListener() async throws {
  let harness = Harness()
  defer { harness.finish() }
  let response = try await harness.client.send(.list(domain: "d", folder: .root), file: nil)
  #expect(response == .entries(try listing()))
}

@Test(.timeLimit(.minutes(1)))
func connectionLossMapsToDisconnected() async throws {
  let harness = Harness()
  defer { harness.finish() }
  var started = harness.started.makeAsyncIterator()
  let client = harness.client
  let call = Task { try await client.send(.status, file: nil) }
  await started.next()
  harness.listener.invalidate()
  await #expect(throws: TransportError.deviceDisconnected) { try await call.value }
}

@Test(.timeLimit(.minutes(1)))
func cancelledCallReturnsPromptlyAndConnectionStaysUsable() async throws {
  let harness = Harness()
  defer { harness.finish() }
  var started = harness.started.makeAsyncIterator()
  let client = harness.client
  let call = Task { try await client.send(.status, file: nil) }
  await started.next()
  call.cancel()
  // The agent is still holding `.status`; the call does not wait for it.
  await #expect(throws: TransportError.cancelled) { try await call.value }
  let response = try await client.send(.list(domain: "d", folder: .root), file: nil)
  #expect(response == .entries(try listing()))
}

@Test(.timeLimit(.minutes(1)))
func reconnectsAfterConnectionIsInvalidated() async throws {
  let harness = Harness(refusals: 1)
  defer { harness.finish() }
  await #expect(throws: TransportError.deviceDisconnected) {
    try await harness.client.send(.list(domain: "d", folder: .root), file: nil)
  }
  let response = try await harness.client.send(.list(domain: "d", folder: .root), file: nil)
  #expect(response == .entries(try listing()))
}

@Test(.timeLimit(.minutes(1)))
func unsignedPeerIsRejected() async throws {
  let harness = Harness(signedOnly: true)
  defer { harness.finish() }
  await #expect(throws: TransportError.deviceDisconnected) {
    try await harness.client.send(.list(domain: "d", folder: .root), file: nil)
  }
}

/// Records the progress a request reports.
private final class Reports: Sendable {
  private let values = Mutex<[[UInt64]]>([])
  var all: [[UInt64]] { values.withLock { $0 } }
  func record(_ completed: UInt64, _ total: UInt64) {
    values.withLock { $0.append([completed, total]) }
  }
}

/// The agent's progress comes back over the client's own exported object, to the request that
/// asked for it, all of it before the reply.
@Test(.timeLimit(.minutes(1)))
func progressReachesTheRequestBeforeItsReply() async throws {
  let harness = Harness()
  defer { harness.finish() }
  let target = FileManager.default.temporaryDirectory.appending(
    path: "ferry-ipc-\(UUID().uuidString)")
  try Data().write(to: target)
  defer { try? FileManager.default.removeItem(at: target) }
  let handle = try FileHandle(forWritingTo: target)
  defer { try? handle.close() }
  let reports = Reports()

  let response = try await harness.client.send(
    .fetch(domain: "d", id: listedID), file: handle, progress: reports.record)

  #expect(response == .done)
  #expect(reports.all == [[3, 7], [7, 7]])
  // Another request's handler hears nothing of it.
  let quiet = Reports()
  _ = try await harness.client.send(
    .list(domain: "d", folder: .root), file: nil, progress: quiet.record)
  #expect(quiet.all.isEmpty)
}
