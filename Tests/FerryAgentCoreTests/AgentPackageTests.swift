import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A document package is one item, as FileProvider sees it: its inside is never listed or
/// reported, it is fetched as one archive, and it is created and replaced whole.
@Suite(.timeLimit(.minutes(1)))
struct AgentPackageTests {
  private struct Setup {
    let harness: AgentHarness
    let device: FakeDevice
    let domain: String
    let storage: StorageID

    func id(_ string: String) async throws -> ItemID {
      try await harness.id(try path(string), in: domain)
    }

    func knows(_ string: String) async throws -> Bool {
      try await harness.controller.route(domain).items.knows(try path(string))
    }

    func send(_ request: AgentRequest, file: FileHandle? = nil) async -> AgentResponse {
      await harness.service.handle(request, file: file)
    }
  }

  private func setup(_ seeds: [(String, String)]) async throws -> Setup {
    let device = await makeDevice("A")
    let storage = storageID(device)
    for (file, contents) in seeds {
      try await device.seed(try path(file), in: storage, contents: Data(contents.utf8))
    }
    let harness = try AgentHarness(devices: [device])
    _ = await harness.manager.waitForCalls(1)
    return Setup(harness: harness, device: device, domain: domainID(device), storage: storage)
  }

  /// An archive of a local package holding `TXT.rtf` (`text`) and `Media/a.png`, open for
  /// reading.
  private func archive(_ text: String, in folder: URL) throws -> FileHandle {
    let package = folder.appending(path: "local.rtfd")
    try FileManager.default.createDirectory(
      at: package.appending(path: "Media"), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: package.appending(path: "TXT.rtf"))
    try Data("png".utf8).write(to: package.appending(path: "Media/a.png"))
    let file = folder.appending(path: "upload.archive")
    #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
    let writer = try FileHandle(forWritingTo: file)
    try PackageArchive.write(tree: package, to: writer)
    try writer.close()
    return try FileHandle(forReadingFrom: file)
  }

  @Test func aListingShowsThePackageButNothingInsideIt() async throws {
    let setup = try await setup([
      ("/Docs/Notes.rtfd/TXT.rtf", "rtf"), ("/Docs/Notes.rtfd/Media/a.png", "png"),
      ("/Docs/a.txt", "a"),
    ])
    defer { setup.harness.finish() }
    // An inside item a table from before this round recorded.
    _ = try await setup.id("/Docs/Notes.rtfd/TXT.rtf")

    let reply = await setup.send(.list(domain: setup.domain, folder: try await setup.id("/Docs")))

    guard case .entries(let entries) = reply else {
      Issue.record("expected a listing, got \(reply)")
      return
    }
    #expect(entries.compactMap(\.item.path.name) == ["Notes.rtfd", "a.txt"])
    #expect(try await !setup.knows("/Docs/Notes.rtfd/TXT.rtf"))
    #expect(try await !setup.knows("/Docs/Notes.rtfd/Media"))
    let inside = await setup.send(
      .list(domain: setup.domain, folder: try await setup.id("/Docs/Notes.rtfd")))
    #expect(inside == .entries([]))
    #expect(try await !setup.knows("/Docs/Notes.rtfd/TXT.rtf"))
  }

  @Test func aPackageIsFetchedAsOneArchiveWithEverythingInIt() async throws {
    let setup = try await setup([
      ("/Notes.rtfd/TXT.rtf", "rtf"), ("/Notes.rtfd/Media/a.png", "png"),
    ])
    defer { setup.harness.finish() }
    let folder = try TestScratch.folder("fetch")
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appending(path: "fetched")
    #expect(FileManager.default.createFile(atPath: target.path, contents: nil))
    let handle = try FileHandle(forWritingTo: target)

    let reply = await setup.send(
      .fetch(domain: setup.domain, id: try await setup.id("/Notes.rtfd")), file: handle)
    try handle.close()

    guard case .entry(let entry) = reply else {
      Issue.record("expected the package, got \(reply)")
      return
    }
    #expect(entry.item.kind == .folder)
    let reader = try FileHandle(forReadingFrom: target)
    defer { try? reader.close() }
    let out = folder.appending(path: "out.rtfd")
    try PackageArchive.extract(from: reader, to: out)
    #expect(try Data(contentsOf: out.appending(path: "TXT.rtf")) == Data("rtf".utf8))
    #expect(try Data(contentsOf: out.appending(path: "Media/a.png")) == Data("png".utf8))
    #expect(try await !setup.knows("/Notes.rtfd/TXT.rtf"))
  }

  @Test func aPackageIsCreatedWhole() async throws {
    let setup = try await setup([("/Docs/a.txt", "a")])
    defer { setup.harness.finish() }
    let folder = try TestScratch.folder("create")
    defer { try? FileManager.default.removeItem(at: folder) }

    let reply = await setup.send(
      .createPackage(domain: setup.domain, parent: try await setup.id("/Docs"), name: "Notes.rtfd"),
      file: try archive("new", in: folder))

    guard case .entry(let entry) = reply else {
      Issue.record("expected the package, got \(reply)")
      return
    }
    #expect(entry.item.path == (try path("/Docs/Notes.rtfd")))
    #expect(
      await setup.device.contents(of: try path("/Docs/Notes.rtfd/TXT.rtf"), in: setup.storage)
        == Data("new".utf8))
    #expect(
      await setup.device.contents(of: try path("/Docs/Notes.rtfd/Media/a.png"), in: setup.storage)
        == Data("png".utf8))
    #expect(try await !setup.knows("/Docs/Notes.rtfd/TXT.rtf"))
    let hidden = await setup.device.allPaths(in: setup.storage).filter {
      SafeWriter.isPartial($0.name ?? "") || SafeWriter.isBackup($0.name ?? "")
    }
    #expect(hidden.isEmpty)
  }

  @Test func aPackageIsReplacedWhole() async throws {
    let setup = try await setup([
      ("/Notes.rtfd/TXT.rtf", "old"), ("/Notes.rtfd/gone.png", "x"),
    ])
    defer { setup.harness.finish() }
    let folder = try TestScratch.folder("replace")
    defer { try? FileManager.default.removeItem(at: folder) }
    let id = try await setup.id("/Notes.rtfd")

    let reply = await setup.send(
      .replacePackage(domain: setup.domain, id: id), file: try archive("new", in: folder))

    guard case .entry(let entry) = reply else {
      Issue.record("expected the package, got \(reply)")
      return
    }
    #expect(entry.id == id)
    #expect(
      await setup.device.allPaths(in: setup.storage).map(\.description) == [
        "/Notes.rtfd", "/Notes.rtfd/Media", "/Notes.rtfd/Media/a.png", "/Notes.rtfd/TXT.rtf",
      ])
  }

  /// The new package cannot take the name: the old one is back, whole.
  @Test func aFailedReplaceRestoresTheOldPackage() async throws {
    let setup = try await setup([("/Notes.rtfd/TXT.rtf", "old")])
    defer { setup.harness.finish() }
    let folder = try TestScratch.folder("restore")
    defer { try? FileManager.default.removeItem(at: folder) }
    let id = try await setup.id("/Notes.rtfd")
    await setup.device.failRename(with: .io("rename failed"), skipping: 1)

    let reply = await setup.send(
      .replacePackage(domain: setup.domain, id: id), file: try archive("new", in: folder))

    #expect(reply == .failure(.io("rename failed")))
    #expect(
      await setup.device.allPaths(in: setup.storage).map(\.description) == [
        "/Notes.rtfd", "/Notes.rtfd/TXT.rtf",
      ])
    #expect(
      await setup.device.contents(of: try path("/Notes.rtfd/TXT.rtf"), in: setup.storage)
        == Data("old".utf8))
  }
}

/// A package on the device past the budget (too deep, too many entries, too many bytes) is
/// refused rather than downloaded, and leaves nothing behind.
@Suite(.timeLimit(.minutes(1)))
struct AgentPackageBudgetTests {
  @Test(arguments: [
    TreeBudget(maxDepth: 2, maxEntries: 100, maxBytes: 1 << 20),
    TreeBudget(maxDepth: 32, maxEntries: 3, maxBytes: 1 << 20),
    TreeBudget(maxDepth: 32, maxEntries: 100, maxBytes: 5),
  ])
  func aPackagePastTheBudgetIsNotFetched(budget: TreeBudget) async throws {
    let device = await makeDevice("A")
    let storage = storageID(device)
    for file in ["/Deep.rtfd/a/f", "/Deep.rtfd/a/b/f", "/Deep.rtfd/a/b/c/f"] {
      try await device.seed(try path(file), in: storage, contents: Data("four".utf8))
    }
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let service = AgentService(hub: harness.hub, domains: harness.controller, packageBudget: budget)
    let domain = domainID(device)
    let (target, handle) = try harness.writable("fetched", "")

    let reply = await service.handle(
      .fetch(domain: domain, id: try await harness.id(try path("/Deep.rtfd"), in: domain)),
      file: handle)

    #expect(reply == .failure(.packageTooLarge))
    #expect(try Data(contentsOf: target).isEmpty)
  }
}
