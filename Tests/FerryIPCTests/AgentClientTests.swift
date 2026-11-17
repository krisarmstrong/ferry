import DeviceKit
import Foundation
import Synchronization
import Testing

@testable import FerryIPC

private func listing() throws(TransportError) -> [RemoteItem] {
  [
    RemoteItem(
      path: try RemotePath("/DCIM/a.jpg"), kind: .file, size: 3,
      modified: Date(timeIntervalSince1970: 1_700_000_000))
  ]
}

/// Answers `.list` with `listing()`; parks `.status` until the test releases it.
private struct StubHandler: AgentHandling {
  let started: AsyncStream<Void>.Continuation
  let release: AsyncStream<Void>

  func handle(_ request: AgentRequest) async -> AgentResponse {
    switch request {
    case .list:
      do {
        return .items(try listing())
      } catch {
        return .failure(error)
      }
    case .status:
      started.yield()
      for await _ in release {}
      return .status(devices: [], providerEnabled: false)
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
        ? AgentListenerDelegate(handler: handler)
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

@Test(.timeLimit(.minutes(1)))
func clientServerOverAnonymousListener() async throws {
  let harness = Harness()
  defer { harness.finish() }
  let response = try await harness.client.send(.list(domain: "d", folder: .root))
  #expect(response == .items(try listing()))
}

@Test(.timeLimit(.minutes(1)))
func connectionLossMapsToDisconnected() async throws {
  let harness = Harness()
  defer { harness.finish() }
  var started = harness.started.makeAsyncIterator()
  let client = harness.client
  let call = Task { try await client.send(.status) }
  await started.next()
  harness.listener.invalidate()
  await #expect(throws: TransportError.deviceDisconnected) { try await call.value }
}

@Test(.timeLimit(.minutes(1)))
func reconnectsAfterConnectionIsInvalidated() async throws {
  let harness = Harness(refusals: 1)
  defer { harness.finish() }
  await #expect(throws: TransportError.deviceDisconnected) {
    try await harness.client.send(.list(domain: "d", folder: .root))
  }
  let response = try await harness.client.send(.list(domain: "d", folder: .root))
  #expect(response == .items(try listing()))
}

@Test(.timeLimit(.minutes(1)))
func unsignedPeerIsRejected() async throws {
  let harness = Harness(signedOnly: true)
  defer { harness.finish() }
  await #expect(throws: TransportError.deviceDisconnected) {
    try await harness.client.send(.list(domain: "d", folder: .root))
  }
}
