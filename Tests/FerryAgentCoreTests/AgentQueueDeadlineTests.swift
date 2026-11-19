import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryAgentCore
@testable import FerryIPC

/// T3 over real XPC: a metadata call's deadline runs from when it has its domain's gate, so one
/// queued behind a transfer waits for it; a call cancelled while queued never reaches the device.
@Suite(.timeLimit(.minutes(1)))
struct AgentQueueDeadlineTests {
  /// The agent's service behind an anonymous listener, a client with a short deadline, and an
  /// upload parked on the device, holding the domain's gate, until `release`.
  private struct Setup {
    let harness: AgentHarness
    let device: FakeDevice
    let domain: String
    let listener: NSXPCListener
    let delegate: AgentListenerDelegate
    let client: AgentClient
    let upload: Task<AgentResponse, Never>
    let release: AsyncStream<Void>.Continuation

    /// Returns once `count` requests wait for the domain's gate behind the upload.
    func queued(_ count: Int) async throws {
      let gate = try await harness.controller.items(of: domain).gate
      while await gate.waiting < count, !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(5))
      }
    }

    func finish() {
      release.finish()
      listener.invalidate()
      harness.finish()
    }
  }

  private func parkedUpload() async throws -> Setup {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    await device.onNextUpload {
      startedContinuation.yield()
      for await _ in released {}
    }
    let file = try harness.readable("big.bin", "big")
    let service = harness.service
    let upload = Task {
      await service.handle(
        .create(domain: domain, parent: .root, name: "big.bin", isFolder: false), file: file)
    }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    let listener = NSXPCListener.anonymous()
    let delegate = AgentListenerDelegate(handler: harness.service, role: .provider)
    listener.delegate = delegate
    listener.resume()
    return Setup(
      harness: harness, device: device, domain: domain, listener: listener, delegate: delegate,
      client: AgentClient(endpoint: listener.endpoint, replyDeadline: .milliseconds(100)),
      upload: upload, release: release)
  }

  @Test func aListQueuedBehindATransferIsNotTimedOut() async throws {
    let setup = try await parkedUpload()
    defer { setup.finish() }
    let (client, domain) = (setup.client, setup.domain)
    let listing = Task { try await client.send(.list(domain: domain, folder: .root), file: nil) }
    try await setup.queued(1)

    // Queued behind the upload for four deadlines.
    try await Task.sleep(for: .milliseconds(400))
    setup.release.finish()

    #expect(await setup.upload.value.isEntry)
    guard case .entries(let entries) = try await listing.value else {
      Issue.record("no listing")
      return
    }
    #expect(entries.map(\.item.path) == [try path("/big.bin")])
  }

  @Test func aFolderCreateCancelledWhileQueuedNeverRuns() async throws {
    let setup = try await parkedUpload()
    defer { setup.finish() }
    let (client, domain) = (setup.client, setup.domain)
    let create = Task {
      try await client.send(
        .create(domain: domain, parent: .root, name: "New", isFolder: true), file: nil)
    }
    try await setup.queued(1)
    create.cancel()
    await #expect(throws: TransportError.cancelled) { try await create.value }
    // The agent takes a connection's messages in order: once this is answered (it waits for no
    // gate), the cancel was taken too.
    _ = try await client.send(.changes(domain: domain, since: nil), file: nil)

    setup.release.finish()
    #expect(await setup.upload.value.isEntry)
    // Queued after the create on the same gate: when it answers, the create has had its turn.
    _ = try await client.send(.list(domain: domain, folder: .root), file: nil)

    #expect(
      try await setup.device.list(.root, in: storageID(setup.device)).map(\.path) == [
        try path("/big.bin")
      ])
  }

  /// A wedged device: the list has the gate and the device never answers. The client gives up
  /// after its deadline with `.agentNotResponding` (`.serverUnreachable` for FileProvider).
  @Test func aListTheDeviceNeverAnswersTimesOut() async throws {
    let setup = try await parkedUpload()
    defer { setup.finish() }
    let (client, domain, device) = (setup.client, setup.domain, setup.device)
    setup.release.finish()
    #expect(await setup.upload.value.isEntry)
    await device.suspendNext(.list)
    defer { Task { await device.resume(.list) } }

    await #expect(throws: TransportError.agentNotResponding) {
      try await client.send(.list(domain: domain, folder: .root), file: nil)
    }
  }
}
