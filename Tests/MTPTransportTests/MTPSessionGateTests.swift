import DeviceKit
import Foundation
import Testing

@testable import MTPTransport

/// One operation at a time per session, existence checks that see the device as it is now, and
/// a session that stops talking to a device once it has gone.
struct MTPSessionGateTests {
  /// Collects values from concurrent tasks.
  actor Log<Value: Sendable> {
    private(set) var values: [Value] = []

    func append(_ value: Value) {
      values.append(value)
    }
  }

  @Test func concurrentOperationsAreSerialized() async throws {
    let device = SessionFixture.makeDevice()
    let session = MTPSession(device: device)
    let file = try SessionFixture.localFile(Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    try await withThrowingTaskGroup { group in
      for index in 0..<20 {
        group.addTask {
          _ = try await session.upload(
            from: file, to: SessionFixture.path("/f\(index).txt"), in: SessionFixture.storage,
            progress: SessionFixture.noProgress)
        }
      }
      try await group.waitForAll()
    }

    #expect(await !device.overlapped)
    #expect(await device.children(of: SessionFixture.root).count == 20)
  }

  @Test func gateIsFIFO() async throws {
    let gate = OperationGate()
    let order = Log<Int>()
    let (held, release) = AsyncStream<Void>.makeStream()
    let (entered, signalEntered) = AsyncStream<Void>.makeStream()

    let holder = Task {
      try await gate.run { () async throws(TransportError) in
        signalEntered.yield()
        for await _ in held {}
        await order.append(0)
      }
    }
    for await _ in entered { break }

    var waiters: [Task<Void, any Error>] = []
    for index in 1...5 {
      waiters.append(
        Task {
          try await gate.run { () async throws(TransportError) in await order.append(index) }
        })
      while await gate.waiting < index { await Task.yield() }
    }
    release.finish()

    try await holder.value
    for waiter in waiters { try await waiter.value }
    #expect(await order.values == [0, 1, 2, 3, 4, 5])
  }

  @Test func existenceCheckSeesPhoneSideAddition() async throws {
    let device = SessionFixture.makeDevice()
    let folder = await device.addFolder("DCIM", parent: SessionFixture.root)
    let session = MTPSession(device: device)
    let file = try SessionFixture.localFile(Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    _ = try await session.list(SessionFixture.path("/DCIM"), in: SessionFixture.storage)
    await device.addFile("x", parent: folder, data: Data("theirs".utf8))

    let target = try SessionFixture.path("/DCIM/x")
    await #expect(throws: TransportError.alreadyExists(target)) {
      _ = try await session.upload(
        from: file, to: target, in: SessionFixture.storage, progress: SessionFixture.noProgress)
    }
    await #expect(throws: TransportError.alreadyExists(target)) {
      _ = try await session.makeFolder(target, in: SessionFixture.storage)
    }
    #expect(await device.uploadCount == 0)
  }

  @Test func partialListingThrows() {
    let partial = [
      MTPEntry(
        objectID: 1, parent: 0, name: "a", isFolder: false, size: 1,
        modified: StubMTPDevice.epoch)
    ]
    let errors = [MTPErrorEntry(code: .ptpLayer, text: "PTP: I/O error")]

    #expect(throws: TransportError.io("listing folder failed: PTP: I/O error")) {
      _ = try completeListing(partial, errors: errors, deviceStillPresent: { true })
    }
    #expect(throws: TransportError.deviceDisconnected) {
      _ = try completeListing(partial, errors: errors, deviceStillPresent: { false })
    }
    #expect(
      (try? completeListing(partial, errors: [], deviceStillPresent: { true }))
        == partial)
  }

  @Test func moveFallbackPartialSurvivesConcurrentListing() async throws {
    let device = SessionFixture.makeDevice(capabilities: [])
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("hello".utf8))
    await device.addFolder("dst", parent: SessionFixture.root)
    let session = MTPSession(device: device)
    let writer = SafeWriter(session: session)
    let folder = try SessionFixture.path("/dst")

    let partials = Log<RemotePath>()
    let registered = Log<Bool>()
    let listings = Log<Task<[RemoteItem], any Error>>()
    await device.onUpload { name in
      guard SafeWriter.isPartial(name), let partial = try? folder.appending(name) else { return }
      await partials.append(partial)
      await registered.append(
        await session.partials.contains(partial, in: SessionFixture.storage))
      await listings.append(
        Task { try await writer.visibleList(folder, in: SessionFixture.storage) })
    }

    let moved = try await session.move(
      SessionFixture.path("/a.txt"), toFolder: folder, in: SessionFixture.storage)

    #expect(await registered.values == [true])
    let listing = try #require(await listings.values.first)
    #expect(try await listing.value.map(\.path) == [moved.path])
    #expect(moved.path == (try folder.appending("a.txt")))
    #expect(await device.children(of: SessionFixture.root) == ["dst"])
    let partial = try #require(await partials.values.first)
    #expect(await !session.partials.contains(partial, in: SessionFixture.storage))
  }

  /// Both operations call other device operations internally; through the public, gated ones
  /// they would wait on themselves forever.
  @Test(.timeLimit(.minutes(1)))
  func recursiveDeleteAndMoveFallbackCompleteUnderTheGate() async throws {
    let device = SessionFixture.makeDevice(capabilities: [])
    let tree = await device.addFolder("tree", parent: SessionFixture.root)
    let sub = await device.addFolder("sub", parent: tree)
    await device.addFile("leaf", parent: sub, data: Data("1".utf8))
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("2".utf8))
    await device.addFolder("dst", parent: SessionFixture.root)
    let session = MTPSession(device: device)

    try await session.delete(SessionFixture.path("/tree"), in: SessionFixture.storage)
    _ = try await session.move(
      SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/dst"),
      in: SessionFixture.storage)

    #expect(await device.children(of: SessionFixture.root) == ["dst"])
  }

  @Test func disconnectReleasesHandleAndFailsFast() async throws {
    let device = SessionFixture.makeDevice()
    let session = MTPSession(device: device)
    let file = try SessionFixture.localFile(Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    await device.unplug()
    await #expect(throws: TransportError.deviceDisconnected) {
      _ = try await session.list(.root, in: SessionFixture.storage)
    }
    #expect(await device.closed)

    await device.resetCallCount()
    await #expect(throws: TransportError.deviceDisconnected) {
      _ = try await session.storages()
    }
    await #expect(throws: TransportError.deviceDisconnected) {
      _ = try await session.upload(
        from: file, to: SessionFixture.path("/x"), in: SessionFixture.storage,
        progress: SessionFixture.noProgress)
    }
    #expect(await session.capabilities().isEmpty)
    #expect(await device.callCount == 0)
  }

  @Test func closeReleasesTheDeviceOnce() async {
    let releases = Log<Int>()
    let session = MTPSession(device: SessionFixture.makeDevice()) { await releases.append(1) }

    await session.close()
    await session.close()

    #expect(await releases.values == [1])
  }

  @Test func disconnectReleasesTheDeviceOnce() async {
    let device = SessionFixture.makeDevice()
    let releases = Log<Int>()
    let session = MTPSession(device: device) { await releases.append(1) }

    await device.unplug()
    _ = try? await session.storages()
    #expect(await releases.values == [1])
    await session.close()
    #expect(await releases.values == [1])
  }
}
