import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A device folder named like a package (an `.rtfd`, an app, Android's `com.foo.app`) is a plain
/// folder: what it holds is listed as items of their own, and a delete without the recursive
/// option keeps it while it holds anything.
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
  func aNonRecursiveDeleteOfAFolderNamedLikeAPackageIsRefused(name: String) async throws {
    let setup = try await setup([("/Android/data/\(name)/cache.db", "x")])
    defer { setup.harness.finish() }
    let folder = try await setup.id("/Android/data/\(name)")

    let reply = await setup.send(
      .delete(domain: setup.domain, id: folder, base: nil, recursive: false))

    #expect(reply == .failure(.directoryNotEmpty(try path("/Android/data/\(name)"))))
    #expect(
      await setup.device.contents(of: try path("/Android/data/\(name)/cache.db"), in: setup.storage)
        != nil)
  }
}
