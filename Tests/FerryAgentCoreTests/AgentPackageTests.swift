import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A device folder named like a package (an `.rtfd`, an app, Android's `com.foo.app`) is a plain
/// folder: what it holds is listed as items of their own. macOS still opens it as an app or a
/// document, so it and everything in it are read-only from the Mac: the agent refuses to change
/// them, though a recursive delete of a folder that holds one takes it.
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

  @Test(arguments: ["Notes.rtfd", "Ferry.app"])
  func aFolderNamedLikeAPackageListsWhatItHolds(name: String) async throws {
    let setup = try await setup([
      ("/Docs/\(name)/TXT.rtf", "rtf"), ("/Docs/\(name)/Media/a.png", "png"),
    ])
    defer { setup.harness.finish() }

    let reply = await setup.send(
      .list(domain: setup.domain, folder: try await setup.id("/Docs/\(name)")))

    guard case .entries(let entries) = reply else {
      Issue.record("expected a listing, got \(reply)")
      return
    }
    #expect(entries.compactMap(\.item.path.name) == ["Media", "TXT.rtf"])
    let text = try #require(entries.first { $0.item.path.name == "TXT.rtf" })
    let (target, handle) = try setup.harness.writable("out", "")
    #expect(await setup.send(.fetch(domain: setup.domain, id: text.id), file: handle).isEntry)
    #expect(try Data(contentsOf: target) == Data("rtf".utf8))
  }

  @Test(arguments: ["com.foo.app", "Notes.rtfd"])
  func aDeleteOfAFolderNamedLikeAPackageIsRefused(name: String) async throws {
    let setup = try await setup([("/Android/data/\(name)/cache.db", "x")])
    defer { setup.harness.finish() }
    let folder = try await setup.id("/Android/data/\(name)")

    let reply = await setup.send(
      .delete(domain: setup.domain, id: folder, base: nil, recursive: false))

    #expect(reply == .failure(.readOnly(try path("/Android/data/\(name)"))))
    #expect(
      await setup.device.contents(of: try path("/Android/data/\(name)/cache.db"), in: setup.storage)
        != nil)
  }

  @Test func nothingInsideAPackageFolderIsChanged() async throws {
    let setup = try await setup([("/Docs/Notes.rtfd/TXT.rtf", "rtf"), ("/Docs/a.txt", "a")])
    defer { setup.harness.finish() }
    let (domain, text) = (setup.domain, try await setup.id("/Docs/Notes.rtfd/TXT.rtf"))
    let (package, docs) = (try await setup.id("/Docs/Notes.rtfd"), try await setup.id("/Docs"))
    let inside = try path("/Docs/Notes.rtfd/TXT.rtf")

    #expect(
      await setup.send(.delete(domain: domain, id: text, base: nil, recursive: false))
        == .failure(.readOnly(inside)))
    #expect(
      await setup.send(.rename(domain: domain, id: text, to: "b.rtf"))
        == .failure(.readOnly(inside)))
    #expect(
      await setup.send(.move(domain: domain, id: text, toFolder: docs))
        == .failure(.readOnly(inside)))
    #expect(
      await setup.send(
        .replaceContents(domain: domain, id: text, base: nil, onConflict: .keepBoth),
        file: try setup.harness.readable("new", "new")) == .failure(.readOnly(inside)))
    #expect(
      await setup.send(
        .create(domain: domain, parent: package, name: "new.txt", isFolder: false),
        file: try setup.harness.readable("new.txt", "n"))
        == .failure(.readOnly(try path("/Docs/Notes.rtfd"))))
    #expect(
      await setup.send(
        .move(domain: domain, id: try await setup.id("/Docs/a.txt"), toFolder: package))
        == .failure(.readOnly(try path("/Docs/Notes.rtfd"))))
    #expect(
      await setup.device.contents(of: inside, in: setup.storage) == Data("rtf".utf8))
  }

  /// The folder that holds a package folder is not read-only: deleting it with its contents
  /// takes the package folder too.
  @Test func aRecursiveDeleteOfAFolderHoldingAPackageFolderTakesIt() async throws {
    let setup = try await setup([("/Docs/Notes.rtfd/TXT.rtf", "rtf")])
    defer { setup.harness.finish() }
    for folder in ["/Docs", "/Docs/Notes.rtfd"] {
      _ = await setup.send(.list(domain: setup.domain, folder: try await setup.id(folder)))
    }

    let reply = await setup.send(
      .delete(domain: setup.domain, id: try await setup.id("/Docs"), base: nil, recursive: true))

    #expect(reply == .done)
    #expect(await setup.device.allPaths(in: setup.storage).isEmpty)
  }

  /// The package-named folder itself: no rename, move, delete (recursive or not) or create in it.
  @Test func aPackageFolderItselfIsRefused() async throws {
    let setup = try await setup([("/Docs/Notes.rtfd/TXT.rtf", "rtf"), ("/Other/x.txt", "x")])
    defer { setup.harness.finish() }
    for folder in ["/Docs", "/Docs/Notes.rtfd"] {
      _ = await setup.send(.list(domain: setup.domain, folder: try await setup.id(folder)))
    }
    let (domain, package) = (setup.domain, try await setup.id("/Docs/Notes.rtfd"))
    let refused = AgentResponse.failure(.readOnly(try path("/Docs/Notes.rtfd")))

    #expect(await setup.send(.rename(domain: domain, id: package, to: "Old.rtfd")) == refused)
    #expect(await setup.send(.rename(domain: domain, id: package, to: "Plain")) == refused)
    #expect(
      await setup.send(.move(domain: domain, id: package, toFolder: try await setup.id("/Other")))
        == refused)
    for recursive in [false, true] {
      #expect(
        await setup.send(.delete(domain: domain, id: package, base: nil, recursive: recursive))
          == refused)
    }
    #expect(
      await setup.send(.create(domain: domain, parent: package, name: "Sub", isFolder: true))
        == refused)
    #expect(
      await setup.device.contents(of: try path("/Docs/Notes.rtfd/TXT.rtf"), in: setup.storage)
        == Data("rtf".utf8))
  }

  /// A file named like a package is a file: the agent asks the device when its table does not
  /// know the kind, rather than taking it for a folder.
  @Test func aFileNamedLikeAPackageCanBeRenamed() async throws {
    let setup = try await setup([("/Docs/report.rtfd", "a file")])
    defer { setup.harness.finish() }

    let reply = await setup.send(
      .rename(domain: setup.domain, id: try await setup.id("/Docs/report.rtfd"), to: "r.txt"))

    #expect(reply.isEntry)
  }
}
