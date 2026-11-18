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
  let bad: RemotePath
  let renamed: RemotePath
  let upload: RemotePath
  let partial: RemotePath
  let moved: RemotePath
  let movedFile: RemotePath

  init() throws {
    docs = try RemotePath("/Docs")
    old = try RemotePath("/Docs/old.txt")
    new = try RemotePath("/Docs/new.txt")
    bad = try RemotePath("/Docs/bad.txt")
    renamed = try RemotePath("/Docs/renamed.txt")
    upload = try RemotePath("/Docs/up.txt")
    partial = try RemotePath("/Docs/\(SafeWriter.partialPrefix)mine")
    moved = try RemotePath("/Moved")
    movedFile = try RemotePath("/Moved/renamed.txt")
  }
}

private struct Ready {
  let harness: AgentHarness
  let device: FakeDevice
  let domain: String
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

    let hello = try harness.readable("new.txt", "hello")
    let created = await harness.service.handle(
      .create(domain: domain, path: paths.new, isFolder: false), file: hello)

    guard case .item(let item) = created else {
      Issue.record("expected an item, got \(created)")
      return
    }
    #expect(item.path == paths.new)
    #expect(await signals(harness) == [.signal(domain, paths.docs)])

    // A direct upload would leave the truncated file under its real name; SafeWriter uploads to a
    // partial and deletes it.
    await device.failUpload(afterBytes: 2, with: .io("boom"))
    let doomed = try harness.readable("bad.txt", "hello")
    let failed = await harness.service.handle(
      .create(domain: domain, path: paths.bad, isFolder: false), file: doomed)
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

    let hello = try harness.readable("new.txt", "hello")
    let newer = try harness.readable("replacement.txt", "newer contents")
    let created = await harness.service.handle(
      .create(domain: domain, path: paths.new, isFolder: false), file: hello)
    let replaced = await harness.service.handle(
      .replaceContents(domain: domain, path: paths.old), file: newer)

    guard case .item = created, case .item = replaced else {
      Issue.record("expected items, got \(created) and \(replaced)")
      return
    }
    #expect(await device.contents(of: paths.new, in: storage) == Data("hello".utf8))
    #expect(await device.contents(of: paths.old, in: storage) == Data("newer contents".utf8))
  }

  @Test func fetchWritesExactBytesThroughDescriptor() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, domain) = (setup.harness, setup.domain)
    defer { harness.finish() }
    let (target, handle) = try harness.writable("fetched.txt", "stale and longer contents")

    #expect(
      await harness.service.handle(.fetch(domain: domain, path: paths.old), file: handle) == .done)

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
    let upload = AgentRequest.create(domain: domain, path: paths.new, isFolder: false)
    let reader = try FileHandle(forReadingFrom: source)

    guard case .item = await harness.service.handle(upload, file: reader) else {
      Issue.record("upload failed")
      return
    }
    #expect(await device.contents(of: paths.new, in: storageID(device)) == contents)

    let (target, handle) = try harness.writable("large-copy.bin", "")
    let fetch = AgentRequest.fetch(domain: domain, path: paths.new)
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

    let fetch = AgentRequest.fetch(domain: domain, path: paths.old)
    #expect(await harness.service.handle(fetch, file: pipe.fileHandleForWriting) == rejected)
    let create = AgentRequest.create(domain: domain, path: paths.new, isFolder: false)
    #expect(await harness.service.handle(create, file: pipe.fileHandleForReading) == rejected)
    let replace = AgentRequest.replaceContents(domain: domain, path: paths.old)
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

    let file = AgentRequest.create(domain: domain, path: paths.new, isFolder: false)
    #expect(await service.handle(file, file: nil) == bad)
    #expect(await service.handle(.fetch(domain: domain, path: paths.old), file: nil) == bad)
    #expect(
      await service.handle(.replaceContents(domain: domain, path: paths.old), file: nil) == bad)
    let stray = try harness.readable("x.txt", "x")
    let folder = AgentRequest.create(domain: domain, path: paths.moved, isFolder: true)
    #expect(await service.handle(folder, file: stray) == bad)
    #expect(await service.handle(.status, file: stray) == bad)
  }

  @Test func mutationsSignalEveryAffectedParent() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let service = harness.service

    let folder = AgentRequest.create(domain: domain, path: paths.moved, isFolder: true)
    let rename = AgentRequest.rename(domain: domain, path: paths.old, to: "renamed.txt")
    let move = AgentRequest.move(domain: domain, path: paths.renamed, toFolder: paths.moved)
    guard
      case .item = await service.handle(folder, file: nil),
      case .item = await service.handle(rename, file: nil),
      case .item = await service.handle(move, file: nil)
    else {
      Issue.record("a mutation failed")
      return
    }
    #expect(
      await service.handle(.delete(domain: domain, path: paths.movedFile), file: nil) == .done)

    let root = FakeDomainManager.Call.signal(domain, .root)
    let docs = FakeDomainManager.Call.signal(domain, paths.docs)
    let moved = FakeDomainManager.Call.signal(domain, paths.moved)
    // Create, rename, move (both parents), delete.
    #expect(await signals(harness) == [root, docs, docs, moved, moved])
    #expect(await device.allPaths(in: storageID(device)) == [paths.docs, paths.moved])
  }

  @Test func unknownDomainFails() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let harness = setup.harness
    defer { harness.finish() }

    #expect(
      await harness.service.handle(.list(domain: "nope", folder: .root), file: nil)
        == .failure(.storageNotFound("nope")))
    #expect(
      await harness.service.handle(.item(domain: "nope", path: paths.docs), file: nil)
        == .failure(.storageNotFound("nope")))
  }

  @Test(arguments: ["a/b", "..", ".", "", "x\0y", SafeWriter.partialPrefix + "x"])
  func renameRejectsInvalidNames(_ name: String) async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }

    let rename = AgentRequest.rename(domain: domain, path: paths.old, to: name)
    #expect(await harness.service.handle(rename, file: nil) == .failure(.invalidName(name)))
    #expect(await device.contents(of: paths.old, in: storageID(device)) != nil)
  }

  /// A listing deletes anything named like a partial that no writer holds, so the agent must
  /// never create one under a client's name.
  @Test func createRejectsPartialNames() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let (harness, device, domain) = (setup.harness, setup.device, setup.domain)
    defer { harness.finish() }
    let invalid = AgentResponse.failure(.invalidName(paths.partial.description))

    let folder = AgentRequest.create(domain: domain, path: paths.partial, isFolder: true)
    #expect(await harness.service.handle(folder, file: nil) == invalid)
    let contents = try harness.readable("p.txt", "p")
    let file = AgentRequest.create(domain: domain, path: paths.partial, isFolder: false)
    #expect(await harness.service.handle(file, file: contents) == invalid)

    #expect(await device.allPaths(in: storageID(device)) == [paths.docs, paths.old])
  }
}
