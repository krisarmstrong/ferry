import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryAgentCore
@testable import FerryIPC

/// T3 over real XPC: a metadata call's deadline runs from when its session operation holds the
/// device, so one queued behind a transfer, on its own storage or another of the device's,
/// waits for it; a call cancelled while queued never reaches the device.
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

    /// Returns once `count` operations wait for the device behind the upload.
    func queuedAtTheDevice(_ count: Int) async throws {
      while await device.operationsWaiting < count, !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(5))
      }
    }

    func finish() {
      release.finish()
      listener.invalidate()
      harness.finish()
    }
  }

  /// With `onCard`, the device has an SD card too and runs its operations one at a time, as a
  /// real session does: the upload goes to the card and holds the whole device, and `domain` is
  /// the internal storage's, whose own gate is free.
  private func parkedUpload(onCard: Bool = false) async throws -> Setup {
    let device = await makeDevice("A", keys: onCard ? [internalKey, cardKey] : [internalKey])
    if onCard { await device.serialiseOperations() }
    let harness = try AgentHarness(devices: [device])
    _ = await harness.manager.waitForCalls(onCard ? 2 : 1)
    let domain = domainID(device)
    let target = onCard ? domainID(device, cardKey) : domain
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
        .create(domain: target, parent: .root, name: "big.bin", isFolder: false), file: file)
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

  /// A device with two storages queues requests on its session, not on each storage's gate: a
  /// list on internal storage behind a copy to the SD card has no deadline until the device is
  /// its turn.
  @Test func aListOnOneStorageQueuedBehindAnotherIsNotTimedOut() async throws {
    let setup = try await parkedUpload(onCard: true)
    defer { setup.finish() }
    let (client, domain) = (setup.client, setup.domain)
    let listing = Task { try await client.send(.list(domain: domain, folder: .root), file: nil) }
    try await setup.queuedAtTheDevice(1)

    // Queued behind the card's upload for four deadlines.
    try await Task.sleep(for: .milliseconds(400))
    setup.release.finish()

    #expect(await setup.upload.value.isEntry)
    guard case .entries(let entries) = try await listing.value else {
      Issue.record("no listing")
      return
    }
    #expect(entries.isEmpty)
  }

  /// A folder create on internal storage, cancelled while it waits for the device behind a copy
  /// to the SD card, never reaches the device.
  @Test func aCreateOnOneStorageCancelledWhileQueuedBehindAnotherNeverRuns() async throws {
    let setup = try await parkedUpload(onCard: true)
    defer { setup.finish() }
    let (client, domain) = (setup.client, setup.domain)
    let create = Task {
      try await client.send(
        .create(domain: domain, parent: .root, name: "New", isFolder: true), file: nil)
    }
    try await setup.queuedAtTheDevice(1)
    create.cancel()
    await #expect(throws: TransportError.cancelled) { try await create.value }
    // The agent takes a connection's messages in order: once this is answered (it waits for
    // nothing), the cancel was taken too.
    _ = try await client.send(.changes(domain: domain, since: nil), file: nil)

    setup.release.finish()
    #expect(await setup.upload.value.isEntry)
    // Queued after the create on the device: when it answers, the create has had its turn.
    _ = try await client.send(.list(domain: domain, folder: .root), file: nil)

    #expect(try await setup.device.list(.root, in: storageID(setup.device)).isEmpty)
  }
}
