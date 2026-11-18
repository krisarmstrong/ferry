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
  let moved: RemotePath
  let movedFile: RemotePath

  init() throws {
    docs = try RemotePath("/Docs")
    old = try RemotePath("/Docs/old.txt")
    new = try RemotePath("/Docs/new.txt")
    bad = try RemotePath("/Docs/bad.txt")
    renamed = try RemotePath("/Docs/renamed.txt")
    upload = try RemotePath("/Docs/up.txt")
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
    let harness = setup.harness
    let device = setup.device
    let domain = setup.domain
    defer { harness.finish() }
    let source = try harness.source("new.txt", "hello")

    let created = await harness.service.handle(
      .create(domain: domain, path: paths.new, from: source, isFolder: false))

    guard case .item(let item) = created else {
      Issue.record("expected an item, got \(created)")
      return
    }
    #expect(item.path == paths.new)
    #expect(await device.contents(of: paths.new, in: storageID(device)) == Data("hello".utf8))
    #expect(await signals(harness) == [.signal(domain, paths.docs)])

    // A direct upload would leave the truncated file under its real name; SafeWriter uploads to a
    // partial and deletes it.
    await device.failUpload(afterBytes: 2, with: .io("boom"))
    let failed = await harness.service.handle(
      .create(domain: domain, path: paths.bad, from: source, isFolder: false))
    #expect(failed == .failure(.io("boom")))
    let kept = [paths.docs, paths.new, paths.old]
    #expect(await device.allPaths(in: storageID(device)) == kept)
    #expect(await signals(harness).count == 1)

    // Replacing contents goes through the same writer.
    let replacement = try harness.source("replacement.txt", "newer")
    let replaced = await harness.service.handle(
      .replaceContents(domain: domain, path: paths.old, from: replacement))
    guard case .item = replaced else {
      Issue.record("expected an item, got \(replaced)")
      return
    }
    #expect(await device.contents(of: paths.old, in: storageID(device)) == Data("newer".utf8))
    #expect(await device.allPaths(in: storageID(device)).count == 3)
  }

  @Test func mutationsSignalEveryAffectedParent() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let harness = setup.harness
    let device = setup.device
    let domain = setup.domain
    defer { harness.finish() }
    let service = harness.service

    guard
      case .item = await service.handle(
        .create(domain: domain, path: paths.moved, from: nil, isFolder: true)),
      case .item = await service.handle(
        .rename(domain: domain, path: paths.old, to: "renamed.txt")),
      case .item = await service.handle(
        .move(domain: domain, path: paths.renamed, toFolder: paths.moved))
    else {
      Issue.record("a mutation failed")
      return
    }
    #expect(await service.handle(.delete(domain: domain, path: paths.movedFile)) == .done)

    let root = FakeDomainManager.Call.signal(domain, .root)
    let docs = FakeDomainManager.Call.signal(domain, paths.docs)
    let moved = FakeDomainManager.Call.signal(domain, paths.moved)
    // Create, rename, move (both parents), delete.
    #expect(await signals(harness) == [root, docs, docs, moved, moved])
    #expect(await device.allPaths(in: storageID(device)) == [paths.docs, paths.moved])
  }

  @Test func fetchReplacesTheGivenFile() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let harness = setup.harness
    let domain = setup.domain
    defer { harness.finish() }
    let target = try harness.source("fetched.txt", "stale contents")

    #expect(
      await harness.service.handle(.fetch(domain: domain, path: paths.old, to: target))
        == .done)

    #expect(try Data(contentsOf: target) == Data("old".utf8))
  }

  @Test func unknownDomainFails() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let harness = setup.harness
    defer { harness.finish() }

    #expect(
      await harness.service.handle(.list(domain: "nope", folder: .root))
        == .failure(.storageNotFound("nope")))
    #expect(
      await harness.service.handle(.item(domain: "nope", path: paths.docs))
        == .failure(.storageNotFound("nope")))
  }

  @Test(arguments: ["a/b", "..", ".", "", "x\0y"])
  func renameRejectsInvalidNames(_ name: String) async throws {
    let paths = try Paths()
    let setup = try await ready()
    let harness = setup.harness
    let device = setup.device
    let domain = setup.domain
    defer { harness.finish() }

    #expect(
      await harness.service.handle(.rename(domain: domain, path: paths.old, to: name))
        == .failure(.invalidName(name)))
    #expect(await device.contents(of: paths.old, in: storageID(device)) != nil)
  }

  @Test func fileURLsMustLieInsideContainer() async throws {
    let paths = try Paths()
    let setup = try await ready()
    let harness = setup.harness
    let domain = setup.domain
    defer { harness.finish() }
    let outside = FileManager.default.temporaryDirectory.appending(
      path: "ferry-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let secret = outside.appending(path: "secret.txt")
    try Data("secret".utf8).write(to: secret)
    let fileLink = harness.container.appending(path: "file-link")
    try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: secret)
    let folderLink = harness.container.appending(path: "folder-link")
    try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: outside)
    let rejected = TransportError.io("url outside container")
    let remote = paths.old

    let throughFolderLink = folderLink.appending(path: "new.txt")
    let planted = outside.appending(path: "planted.txt")
    let dangling = harness.container.appending(path: "dangling")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: planted)
    let dotDot = URL(fileURLWithPath: harness.container.path + "/../escape.txt")
    let siblingPrefix = URL(fileURLWithPath: harness.container.path + "-evil/new.txt")
    let remoteURL = try #require(URL(string: "https://example.com/new.txt"))
    let links = [fileLink, throughFolderLink, dangling]
    let escapes = links + [dotDot, siblingPrefix, harness.container, remoteURL]
    for url in escapes {
      #expect(
        await harness.service.handle(.fetch(domain: domain, path: remote, to: url))
          == .failure(rejected), "fetch to \(url)")
      #expect(
        await harness.service.handle(
          .create(domain: domain, path: paths.upload, from: url, isFolder: false))
          == .failure(rejected), "create from \(url)")
      #expect(
        await harness.service.handle(.replaceContents(domain: domain, path: remote, from: url))
          == .failure(rejected), "replace from \(url)")
    }
    #expect(try Data(contentsOf: secret) == Data("secret".utf8))
    #expect(!FileManager.default.fileExists(atPath: planted.path))

    // A destination that does not exist yet, under the temporary directory's /var symlink.
    let fresh = harness.container.appending(path: "fresh.txt")
    #expect(await harness.service.handle(.fetch(domain: domain, path: remote, to: fresh)) == .done)
    #expect(try Data(contentsOf: fresh) == Data("old".utf8))
  }
}
