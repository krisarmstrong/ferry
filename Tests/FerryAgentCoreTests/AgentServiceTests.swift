import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The device paths these tests use.
private struct Paths {
  let docs: RemotePath
  let old: RemotePath
  let new: RemotePath
  let renamed: RemotePath
  let moved: RemotePath
  let movedFile: RemotePath

  init() throws {
    docs = try RemotePath("/Docs")
    old = try RemotePath("/Docs/old.txt")
    new = try RemotePath("/Docs/new.txt")
    renamed = try RemotePath("/Docs/renamed.txt")
    moved = try RemotePath("/Moved")
    movedFile = try RemotePath("/Moved/renamed.txt")
  }
}

private struct Ready {
  let harness: AgentHarness
  let device: FakeDevice
  let domain: String

  func id(_ path: RemotePath) async throws -> ItemID {
    try await harness.id(path, in: domain)
  }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentServiceTests {
  /// A harness with one ready device holding `/Docs/old.txt`, once its domain is added.
  private func ready() async throws -> Ready {
    let paths = try Paths()
    let device = await makeDevice("A")
    try await device.seed(paths.old, in: storageID(device), contents: Data("old".utf8))
    let harness = try AgentHarness(devices: [device])
    _ = await harness.manager.waitForCalls(1)
    return Ready(harness: harness, device: device, domain: domainID(device))
  }

  private func signals(_ harness: AgentHarness) async -> [FakeDomainManager.Call] {
    await harness.manager.calls.filter {
      if case .signal = $0 { return true }
      return false
    }
  }

  @Test func writeGoesThroughSafeWriterAndSignals() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }

    let docs = try await setup.id(paths.docs)
    let hello = try harness.readable("new.txt", "hello")
    let created = await harness.service.handle(
      .create(domain: domain, parent: docs, name: "new.txt", isFolder: false), file: hello)

    guard case .entry(let entry) = created else {
      Issue.record("expected an entry, got \(created)")
      return
    }
    #expect(entry.item.path == paths.new)
    #expect(entry.parent == docs)
    #expect(entry.id == (try await setup.id(paths.new)))
    #expect(await signals(harness) == [.signal(domain)])

    // A direct upload would leave the truncated file under its real name; SafeWriter uploads to a
    // partial and deletes it.
    await device.failUpload(afterBytes: 2, with: .io("boom"))
    let doomed = try harness.readable("bad.txt", "hello")
    let failed = await harness.service.handle(
      .create(domain: domain, parent: docs, name: "bad.txt", isFolder: false), file: doomed)
    #expect(failed == .failure(.io("boom")))
    let kept = [paths.docs, paths.new, paths.old]
    #expect(await device.allPaths(in: storageID(device)) == kept)
    #expect(await signals(harness).count == 1)
  }

  @Test func createAndReplaceReadTheWholeDescriptor() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let storage = storageID(device)

    let old = try await setup.id(paths.old)
    let hello = try harness.readable("new.txt", "hello")
    let newer = try harness.readable("replacement.txt", "newer contents")
    let created = await harness.service.handle(
      .create(
        domain: domain, parent: try await setup.id(paths.docs), name: "new.txt",
        isFolder: false),
      file: hello)
    let replaced = await harness.service.handle(
      .replaceContents(domain: domain, id: old), file: newer)

    guard case .entry = created, case .entry(let entry) = replaced else {
      Issue.record("expected entries, got \(created) and \(replaced)")
      return
    }
    #expect(entry.id == old)
    #expect(await device.contents(of: paths.new, in: storage) == Data("hello".utf8))
    #expect(await device.contents(of: paths.old, in: storage) == Data("newer contents".utf8))
  }

  @Test func fetchWritesExactBytesThroughDescriptor() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, domain) = (setup.harness, setup.domain)
    defer { harness.finish() }
    let (target, handle) = try harness.writable("fetched.txt", "stale and longer contents")

    let fetch = AgentRequest.fetch(domain: domain, id: try await setup.id(paths.old))
    #expect(await harness.service.handle(fetch, file: handle) == .done)

    #expect(try Data(contentsOf: target) == Data("old".utf8))
  }

  /// Larger than the copy's chunk, and not a multiple of it, in both directions.
  @Test func filesLargerThanOneChunkCopyIntact() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let contents = Data((0..<(5 << 19) + 17).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let source = harness.scratch.appending(path: "large.bin")
    try contents.write(to: source)
    let upload = AgentRequest.create(
      domain: domain, parent: try await setup.id(paths.docs), name: "new.txt", isFolder: false)
    let reader = try FileHandle(forReadingFrom: source)

    guard case .entry(let entry) = await harness.service.handle(upload, file: reader) else {
      Issue.record("upload failed")
      return
    }
    #expect(await device.contents(of: paths.new, in: storageID(device)) == contents)

    let (target, handle) = try harness.writable("large-copy.bin", "")
    let fetch = AgentRequest.fetch(domain: domain, id: entry.id)
    #expect(await harness.service.handle(fetch, file: handle) == .done)
    #expect(try Data(contentsOf: target) == contents)
  }

  @Test func nonRegularDescriptorsAreRejected() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let pipe = Pipe()
    // Foundation will not open a folder for reading, but a client could send one's descriptor.
    let folderDescriptor = open(harness.scratch.path, O_RDONLY)
    try #require(folderDescriptor >= 0)
    let folder = FileHandle(fileDescriptor: folderDescriptor, closeOnDealloc: true)
    let rejected = AgentResponse.failure(.io("not a regular file"))
    let old = try await setup.id(paths.old)

    let fetch = AgentRequest.fetch(domain: domain, id: old)
    #expect(await harness.service.handle(fetch, file: pipe.fileHandleForWriting) == rejected)
    let create = AgentRequest.create(
      domain: domain, parent: try await setup.id(paths.docs), name: "new.txt", isFolder: false)
    #expect(await harness.service.handle(create, file: pipe.fileHandleForReading) == rejected)
    let replace = AgentRequest.replaceContents(domain: domain, id: old)
    #expect(await harness.service.handle(replace, file: folder) == rejected)

    #expect(await device.allPaths(in: storageID(device)) == [paths.docs, paths.old])
  }

  @Test func missingOrUnexpectedDescriptorFails() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, domain) = (setup.harness, setup.domain)
    defer { harness.finish() }
    let bad = AgentResponse.failure(.io("bad request"))
    let service = harness.service

    let old = try await setup.id(paths.old)
    let file = AgentRequest.create(domain: domain, parent: .root, name: "new", isFolder: false)
    #expect(await service.handle(file, file: nil) == bad)
    #expect(await service.handle(.fetch(domain: domain, id: old), file: nil) == bad)
    #expect(await service.handle(.replaceContents(domain: domain, id: old), file: nil) == bad)
    let stray = try harness.readable("x.txt", "x")
    let folder = AgentRequest.create(domain: domain, parent: .root, name: "Moved", isFolder: true)
    #expect(await service.handle(folder, file: stray) == bad)
    #expect(await service.handle(.status, file: stray) == bad)
  }

  @Test func mutationRecordsChangeAndSignals() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let service = harness.service
    let old = try await setup.id(paths.old)
    guard
      case .changes(let anchor, _, _, _) = await service.handle(
        .changes(domain: domain, since: nil), file: nil)
    else {
      Issue.record("expected an anchor")
      return
    }

    let folder = AgentRequest.create(domain: domain, parent: .root, name: "Moved", isFolder: true)
    guard case .entry(let made) = await service.handle(folder, file: nil) else {
      Issue.record("making a folder failed")
      return
    }
    let rename = AgentRequest.rename(domain: domain, id: old, to: "renamed.txt")
    let move = AgentRequest.move(domain: domain, id: old, toFolder: made.id)
    guard
      case .entry(let renamed) = await service.handle(rename, file: nil),
      case .entry(let moved) = await service.handle(move, file: nil)
    else {
      Issue.record("a mutation failed")
      return
    }
    #expect([renamed.id, moved.id] == [old, old])
    #expect(renamed.item.path == paths.renamed)
    #expect(moved.item.path == paths.movedFile)
    #expect(moved.parent == made.id)
    #expect(await service.handle(.delete(domain: domain, id: old), file: nil) == .done)
    #expect(
      await service.handle(.item(domain: domain, id: old), file: nil) == .failure(.unknownItem))

    // Create, rename, move, delete: one working-set signal each.
    #expect(await signals(harness) == Array(repeating: .signal(domain), count: 4))
    #expect(await device.allPaths(in: storageID(device)) == [paths.docs, paths.moved])
    // The renamed and moved file is reported once, as deleted; the folder as it is now.
    #expect(
      await service.handle(.changes(domain: domain, since: anchor), file: nil)
        == .changes(
          anchor: try await changesAnchor(service, domain), updated: [made],
          deleted: [old], expired: false))
  }

  private func changesAnchor(_ service: AgentService, _ domain: String) async throws -> Data {
    guard
      case .changes(let anchor, _, _, _) = await service.handle(
        .changes(domain: domain, since: nil), file: nil)
    else { throw TransportError.io("no anchor") }
    return anchor
  }

  @Test func unknownDomainFails() async throws {
    let setup = try await ready()
    let harness = setup.harness
    defer { harness.finish() }

    #expect(
      await harness.service.handle(.list(domain: "nope", folder: .root), file: nil)
        == .failure(.deviceDisconnected))
    #expect(
      await harness.service.handle(.item(domain: "nope", id: .root), file: nil)
        == .failure(.deviceDisconnected))
  }

  @Test(
    arguments: [
      "a/b", "..", ".", "", "x\0y", SafeWriter.partialPrefix + "x", SafeWriter.backupPrefix + "x",
    ])
  func renameRejectsInvalidNames(_ name: String) async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }

    let rename = AgentRequest.rename(domain: domain, id: try await setup.id(paths.old), to: name)
    #expect(await harness.service.handle(rename, file: nil) == .failure(.invalidName(name)))
    #expect(await device.contents(of: paths.old, in: storageID(device)) != nil)
  }

  /// A listing deletes anything named like a partial that no writer holds, so the agent must
  /// never create one under a client's name.
  @Test(
    arguments: [
      "a/b", "..", ".", "", "x\0y", SafeWriter.partialPrefix + "mine",
      SafeWriter.backupPrefix + "mine",
    ])
  func createRejectsInvalidNames(_ name: String) async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let invalid = AgentResponse.failure(.invalidName(name))
    let docs = try await setup.id(paths.docs)

    let folder = AgentRequest.create(domain: domain, parent: docs, name: name, isFolder: true)
    #expect(await harness.service.handle(folder, file: nil) == invalid)
    let contents = try harness.readable("p.txt", "p")
    let file = AgentRequest.create(domain: domain, parent: docs, name: name, isFolder: false)
    #expect(await harness.service.handle(file, file: contents) == invalid)

    #expect(await device.allPaths(in: storageID(device)) == [paths.docs, paths.old])
  }
}

/// A card taken out of a device that stays plugged in: the card's domain is unreachable, not
/// empty, so FileProvider keeps its items, and the agent disconnects it.
@Suite(.timeLimit(.minutes(1)))
struct AgentServiceStorageGoneTests {
  @Test func aRemovedCardDisconnectsItsDomainRatherThanLosingItems() async throws {
    let device = await makeDevice("A", keys: [internalKey, cardKey])
    let card = storageID(device, cardKey)
    try await device.seed(try path("/DCIM/a.jpg"), in: card, contents: Data("jpg".utf8))
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let cardDomain = domainID(device, cardKey)
    _ = await harness.manager.waitForCalls(2)

    await device.removeStorage(card)
    let reply = await harness.service.handle(.list(domain: cardDomain, folder: .root), file: nil)

    guard case .failure(let error) = reply else {
      Issue.record("expected a failure, got \(reply)")
      return
    }
    #expect(error == .storageNotFound(card.key))
    let after = await harness.manager.waitForCalls(3)
    #expect(after.contains(.disconnect(cardDomain)))
  }
}
