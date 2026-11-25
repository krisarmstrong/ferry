import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// I6: a client's cancel, which the agent's XPC layer hands its request as
/// `RequestCancellation.current`, stops the transfer at its next block, and the device keeps no
/// partial and the file it was replacing.
@Suite(.timeLimit(.minutes(1)))
struct AgentTransferCancelTests {
  private struct Setup {
    let harness: AgentHarness
    let device: FakeDevice
    let domain: String
  }

  private func setUp() async throws -> Setup {
    let device = await makeDevice("A")
    try await device.seed(try path("/a.txt"), in: storageID(device), contents: Data("old".utf8))
    let harness = try AgentHarness(devices: [device])
    _ = await harness.manager.waitForCalls(1)
    return Setup(harness: harness, device: device, domain: domainID(device))
  }

  /// Runs `request` as the XPC layer does, cancelled by its client once the device starts
  /// taking the file.
  private func cancelled(
    _ request: AgentRequest, file: FileHandle, on harness: AgentHarness, device: FakeDevice
  ) async -> AgentResponse {
    let cancellation = RequestCancellation()
    await device.onNextUpload { cancellation.cancel() }
    return await RequestCancellation.$current.withValue(cancellation) {
      await harness.service.handle(request, file: file)
    }
  }

  @Test func aCancelledReplaceKeepsTheFile() async throws {
    let setup = try await setUp()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let id = try await harness.id(try path("/a.txt"), in: domain)

    let response = await cancelled(
      .replaceContents(domain: domain, id: id, base: nil, onConflict: .keepBoth),
      file: try harness.readable("new.txt", "newer contents"), on: harness, device: device)

    #expect(response == .failure(.cancelled))
    let storage = storageID(device)
    #expect(try await device.list(.root, in: storage).map(\.path) == [try path("/a.txt")])
    #expect(await device.contents(of: try path("/a.txt"), in: storage) == Data("old".utf8))
  }

  /// A request cancelled while the agent copies the client's file stops that copy: nothing
  /// reaches the device, and no scratch copy is left on the Mac.
  @Test func aCancelBeforeTheDeviceIsReachedStopsTheCopy() async throws {
    let setup = try await setUp()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let reached = Mutex(false)
    await device.onNextUpload { reached.withLock { $0 = true } }
    let cancellation = RequestCancellation()
    cancellation.cancel()
    let file = try harness.readable("big.txt", String(repeating: "x", count: 3 << 20))

    let response = await RequestCancellation.$current.withValue(cancellation) {
      await harness.service.handle(
        .create(domain: domain, parent: .root, name: "big.txt", isFolder: false),
        file: file)
    }

    #expect(response == .failure(.cancelled))
    #expect(reached.withLock { $0 } == false)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: harness.scratch.path) == ["big.txt"])
  }

  @Test func aCancelledUploadLeavesNothing() async throws {
    let setup = try await setUp()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }

    let response = await cancelled(
      .create(domain: domain, parent: .root, name: "b.txt", isFolder: false),
      file: try harness.readable("b.txt", "b"), on: harness, device: device)

    #expect(response == .failure(.cancelled))
    #expect(
      try await device.list(.root, in: storageID(device)).map(\.path) == [try path("/a.txt")])
  }

  /// The device's file changed since the Mac read it, so the Mac's contents would go up beside
  /// it as a conflict copy; a cancel stops that upload too, leaving no copy and no partial.
  @Test func aCancelledConflictCopyLeavesNothing() async throws {
    let setup = try await setUp()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let id = try await harness.id(try path("/a.txt"), in: domain)
    let stale = ContentVersion(
      RemoteItem(
        path: try path("/a.txt"), kind: .file, size: 999,
        modified: Date(timeIntervalSince1970: 1_000_000_000)))

    let response = await cancelled(
      .replaceContents(domain: domain, id: id, base: stale, onConflict: .keepBoth),
      file: try harness.readable("new.txt", "newer contents"), on: harness, device: device)

    #expect(response == .failure(.cancelled))
    let storage = storageID(device)
    #expect(try await device.list(.root, in: storage).map(\.path) == [try path("/a.txt")])
    #expect(await device.contents(of: try path("/a.txt"), in: storage) == Data("old".utf8))
  }

  /// A request nobody can cancel runs as before.
  @Test func anUploadWithNoCancellationGoesUp() async throws {
    let setup = try await setUp()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let response = await harness.service.handle(
      .create(domain: domain, parent: .root, name: "b.txt", isFolder: false),
      file: try harness.readable("b.txt", "b"))
    #expect(response.isEntry)
    #expect(await device.contents(of: try path("/b.txt"), in: storageID(device)) == Data("b".utf8))
  }
}
