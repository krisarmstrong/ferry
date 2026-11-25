import CryptoKit
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// What Finder is told after a transfer fails part-way: never success for bytes that did not
/// arrive, and never a lost original or an unexplained copy.
@Suite(.timeLimit(.minutes(1)))
struct AgentTransferIntegrityTests {
  private struct Setup {
    let harness: AgentHarness
    let device: FakeDevice
    let domain: String
    let storage: StorageID

    func id(_ string: String) async throws -> ItemID {
      try await harness.id(try path(string), in: domain)
    }

    func send(_ request: AgentRequest, file: FileHandle? = nil) async -> AgentResponse {
      await harness.service.handle(request, file: file)
    }

    func version(_ string: String) async throws -> ContentVersion {
      guard case .entry(let entry) = await send(.item(domain: domain, id: try await id(string)))
      else { throw TransportError.unknownItem }
      return ContentVersion(entry.item)
    }

    func contents(_ string: String) async throws -> Data? {
      await device.contents(of: try path(string), in: storage)
    }

    func create(_ name: String, _ contents: String) async throws -> AgentResponse {
      await send(
        .create(domain: domain, parent: try await id("/Docs"), name: name, isFolder: false),
        file: try harness.readable(name, contents))
    }
  }

  /// The device holds `/Docs/report.txt`, dated an hour ago so a file written now differs.
  private func setup() async throws -> Setup {
    let device = await makeDevice("A")
    let storage = storageID(device)
    try await device.seed(
      try path("/Docs/report.txt"), in: storage, contents: Data("the original".utf8),
      modified: Date(timeIntervalSinceNow: -3600))
    let harness = try AgentHarness(devices: [device])
    _ = await harness.manager.waitForCalls(1)
    return Setup(harness: harness, device: device, domain: domainID(device), storage: storage)
  }

  private static func sha(_ data: Data?) -> String? {
    data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
  }

  // MARK: Downloads

  /// The device goes away mid-download, or the session is lost as it starts: the fetch fails
  /// and Finder's file is not written with what arrived.
  @Test(arguments: [false, true])
  func aDownloadCutOffIsAFailureAndWritesNothing(sessionLost: Bool) async throws {
    let setup = try await setup()
    defer { setup.harness.finish() }
    let device = setup.device
    if sessionLost {
      await device.onNextDownload { await device.setDisconnected() }
    } else {
      await device.failDownload(afterBytes: 3, with: .deviceDisconnected)
    }
    let (target, handle) = try setup.harness.writable("fetched.txt", "")

    let reply = await setup.send(
      .fetch(domain: setup.domain, id: try await setup.id("/Docs/report.txt")), file: handle)

    #expect(reply == .failure(.deviceDisconnected))
    #expect(try Data(contentsOf: target).isEmpty)
  }

  @Test func aDownloadArrivesByteForByte() async throws {
    let setup = try await setup()
    defer { setup.harness.finish() }
    let (target, handle) = try setup.harness.writable("fetched.txt", "")

    let reply = await setup.send(
      .fetch(domain: setup.domain, id: try await setup.id("/Docs/report.txt")), file: handle)

    #expect(reply.isEntry)
    #expect(Self.sha(try Data(contentsOf: target)) == Self.sha(Data("the original".utf8)))
  }

  // MARK: Uploads

  @Test(arguments: [
    TransportError.io("refused by the device"), .insufficientSpace(needed: 0, free: 0),
    .deviceDisconnected,
  ])
  func aCreateTheDeviceRefusesIsAFailureAndLeavesNothing(_ failure: TransportError)
    async throws
  {
    let setup = try await setup()
    defer { setup.harness.finish() }
    await setup.device.failUpload(afterBytes: 2, with: failure)

    let reply = try await setup.create("new.txt", "new contents")

    #expect(reply == .failure(failure))
    #expect(
      await setup.device.allPaths(in: setup.storage) == [
        try path("/Docs"), try path("/Docs/report.txt"),
      ])
  }

  @Test func aCreateArrivesByteForByte() async throws {
    let setup = try await setup()
    defer { setup.harness.finish() }

    #expect(try await setup.create("new.txt", "new contents").isEntry)
    #expect(
      Self.sha(try await setup.contents("/Docs/new.txt")) == Self.sha(Data("new contents".utf8)))
  }

  /// A create that reached the device whose reply did not reach Finder (the extension or the
  /// helper went away first) is sent again. The file is there with these very bytes: that is
  /// the create done, not a name taken, which would make Finder rename its copy to "name 2".
  @Test func aRetriedCreateWhoseFileArrivedIsAnsweredWithIt() async throws {
    let setup = try await setup()
    defer { setup.harness.finish() }
    #expect(try await setup.create("new.txt", "new contents").isEntry)

    let retried = try await setup.create("new.txt", "new contents")

    guard case .entry(let entry) = retried else {
      Issue.record("expected the device's file, got \(retried)")
      return
    }
    #expect(entry.item.path == (try path("/Docs/new.txt")))
    #expect(entry.id == (try await setup.id("/Docs/new.txt")))
    #expect(await setup.device.allPaths(in: setup.storage).count == 3)
  }

  /// Other contents under the name are another file: the collision stands.
  @Test func aCreateOverDifferentContentsIsACollision() async throws {
    let setup = try await setup()
    defer { setup.harness.finish() }

    let reply = try await setup.create("report.txt", "the Mac's own report")

    #expect(reply == .failure(.alreadyExists(try path("/Docs/report.txt"))))
    #expect(try await setup.contents("/Docs/report.txt") == Data("the original".utf8))
  }

  /// Same length is not same file: only the bytes decide.
  @Test func aCreateOverContentsOfTheSameLengthIsACollision() async throws {
    let setup = try await setup()
    defer { setup.harness.finish() }
    // "the original" and "THE ORIGINAL" have the same length.
    let reply = try await setup.create("report.txt", "THE ORIGINAL")

    #expect(reply == .failure(.alreadyExists(try path("/Docs/report.txt"))))
    #expect(try await setup.contents("/Docs/report.txt") == Data("the original".utf8))
  }

  // MARK: Replacing on a device that cannot rename

  /// The upload of a save fails: the original is back, byte for byte, and FileProvider's retry
  /// of the same save, based on the version it had, is no conflict: no conflict copy appears.
  @Test func aFailedSaveOnANoRenameDeviceKeepsTheOriginalAndItsRetryApplies() async throws {
    let setup = try await setup()
    defer { setup.harness.finish() }
    let device = setup.device
    await device.failRename(with: .unsupported("rename"), count: 1000)
    let file = try await setup.id("/Docs/report.txt")
    let base = try await setup.version("/Docs/report.txt")
    // The partial goes up first; the direct upload after the delete fails.
    await device.failUpload(afterBytes: 2, with: .io("refused"), skipping: 1)

    let failed = await setup.send(
      .replaceContents(domain: setup.domain, id: file, base: base, onConflict: .keepBoth),
      file: try setup.harness.readable("mac.txt", "the Mac's save"))

    #expect(failed == .failure(.io("refused")))
    #expect(
      Self.sha(try await setup.contents("/Docs/report.txt"))
        == Self.sha(Data("the original".utf8)))

    let retried = await setup.send(
      .replaceContents(domain: setup.domain, id: file, base: base, onConflict: .keepBoth),
      file: try setup.harness.readable("mac2.txt", "the Mac's save"))

    guard case .entry(let entry) = retried else {
      Issue.record("expected the saved item, got \(retried)")
      return
    }
    #expect(entry.id == file)
    #expect(try await setup.contents("/Docs/report.txt") == Data("the Mac's save".utf8))
    #expect(await device.allPaths(in: setup.storage).count == 2)
  }
}
