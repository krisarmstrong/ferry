import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A recursive delete takes only what Finder showed the user: a folder that, walked fresh, holds
/// anything the agent never reported stays, with all of it, and FileProvider puts it back with
/// the new items in it. So does a tree too deep to walk.
@Suite(.timeLimit(.minutes(1)))
struct AgentRecursiveDeleteTests {
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

    /// Lists each folder, as Finder does when the user opens it.
    func show(_ folders: [String]) async throws {
      for folder in folders {
        #expect(await send(.list(domain: domain, folder: try await id(folder))) != .done)
      }
    }

    func known(_ string: String) async throws -> Bool {
      try await harness.controller.items(of: domain).knows(try path(string))
    }

    func onDevice(_ string: String) async throws -> Bool {
      await device.contents(of: try path(string), in: storage) != nil
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

  @Test func aRecursiveDeleteOfWhatFinderShowedRemovesItAll() async throws {
    let setup = try await setup([("/Reports/r1.txt", "one"), ("/Reports/Sub/r2.txt", "two")])
    defer { setup.harness.finish() }
    try await setup.show(["/Reports", "/Reports/Sub"])

    let reply = await setup.send(
      .delete(domain: setup.domain, id: try await setup.id("/Reports"), base: nil, recursive: true))

    #expect(reply == .done)
    #expect(try await !setup.onDevice("/Reports/r1.txt"))
    #expect(try await !setup.onDevice("/Reports/Sub/r2.txt"))
  }

  @Test func aFolderHoldingItemsFinderNeverSawStays() async throws {
    let setup = try await setup([("/Reports/r1.txt", "one"), ("/Reports/Sub/r2.txt", "two")])
    defer { setup.harness.finish() }
    try await setup.show(["/Reports", "/Reports/Sub"])
    try await setup.device.seed(
      try path("/Reports/Sub/new.txt"), in: setup.storage, contents: Data("new".utf8))

    let reply = await setup.send(
      .delete(domain: setup.domain, id: try await setup.id("/Reports"), base: nil, recursive: true))

    #expect(reply == .failure(.directoryNotEmpty(try path("/Reports"))))
    for file in ["/Reports/r1.txt", "/Reports/Sub/r2.txt", "/Reports/Sub/new.txt"] {
      #expect(try await setup.onDevice(file), "\(file)")
    }
    // Recorded, so FileProvider learns of it with the folder it puts back.
    #expect(try await setup.known("/Reports/Sub/new.txt"))
  }

  /// FileProvider saw the file, but the device changed it since: deleting the folder would
  /// lose the device's edit.
  @Test func aFolderHoldingAFileTheDeviceChangedStays() async throws {
    let setup = try await setup([("/Reports/r1.txt", "one")])
    defer { setup.harness.finish() }
    try await setup.show(["/Reports"])
    try await setup.device.seed(
      try path("/Reports/r1.txt"), in: setup.storage, contents: Data("edited on the unit".utf8))

    let reply = await setup.send(
      .delete(domain: setup.domain, id: try await setup.id("/Reports"), base: nil, recursive: true))

    #expect(reply == .failure(.directoryNotEmpty(try path("/Reports"))))
    #expect(
      await setup.device.contents(of: try path("/Reports/r1.txt"), in: setup.storage)
        == Data("edited on the unit".utf8))
    // The device's version is recorded, so FileProvider shows it in the folder it puts back.
    guard
      case .page(let entries, _) = await setup.send(
        .workingSet(domain: setup.domain, page: nil))
    else { throw TransportError.unknownItem }
    let edited = entries.first { $0.item.path == (try? path("/Reports/r1.txt")) }
    #expect(edited?.item.size == UInt64("edited on the unit".utf8.count))
  }

  /// A folder FileProvider never listed: everything in it is unseen.
  @Test func aFolderFinderNeverOpenedStaysWhileItHoldsAnything() async throws {
    let setup = try await setup([("/Reports/r1.txt", "one")])
    defer { setup.harness.finish() }
    try await setup.show(["/"])

    let reply = await setup.send(
      .delete(domain: setup.domain, id: try await setup.id("/Reports"), base: nil, recursive: true))

    #expect(reply == .failure(.directoryNotEmpty(try path("/Reports"))))
    #expect(try await setup.onDevice("/Reports/r1.txt"))
  }

  /// `d1` holds `d2` … `d<levels>`, the last of them holding `leaf.txt`: the leaf is `levels`
  /// below `d1`. Everything is shown, so only the depth can refuse the delete.
  @Test(arguments: [(RemotePath.maxTreeDepth, true), (RemotePath.maxTreeDepth + 1, false)])
  func aTreeDeeperThanFerryWalksStays(levels: Int, deletes: Bool) async throws {
    let deep = (1...levels).map { "d\($0)" }
    let file = "/" + (deep + ["leaf.txt"]).joined(separator: "/")
    let setup = try await setup([(file, "leaf")])
    defer { setup.harness.finish() }
    let folders = deep.indices.map { "/" + deep[...$0].joined(separator: "/") }
    try await setup.show(["/"] + folders)

    let reply = await setup.send(
      .delete(domain: setup.domain, id: try await setup.id("/d1"), base: nil, recursive: true))

    #expect(reply == (deletes ? .done : .failure(.directoryNotEmpty(try path("/d1")))))
    #expect(try await setup.onDevice(file) == !deletes)
  }

  /// An item the device adds between the walk and the delete: the delete is refused, and the
  /// folder is walked again so FileProvider learns of the new item.
  @Test func anItemAddedDuringTheDeleteIsRecorded() async throws {
    let setup = try await setup([("/Reports/r1.txt", "one")])
    defer { setup.harness.finish() }
    try await setup.show(["/Reports"])
    let (device, storage) = (setup.device, setup.storage)
    await device.onNextDelete {
      try? await device.seed(
        try path("/Reports/late.txt"), in: storage, contents: Data("late".utf8))
    }

    let reply = await setup.send(
      .delete(domain: setup.domain, id: try await setup.id("/Reports"), base: nil, recursive: true))

    #expect(reply == .failure(.directoryNotEmpty(try path("/Reports"))))
    #expect(try await setup.known("/Reports/late.txt"))
    #expect(try await setup.onDevice("/Reports/r1.txt"))
  }

  /// A folder Finder showed empty gains an item before the delete: only its own level is listed
  /// again, and the item is recorded.
  @Test func anItemAddedDuringANonRecursiveDeleteIsRecorded() async throws {
    let setup = try await setup([("/Reports/old.txt", "old")])
    defer { setup.harness.finish() }
    try await setup.show(["/Reports"])
    _ = await setup.send(
      .delete(
        domain: setup.domain, id: try await setup.id("/Reports/old.txt"), base: nil,
        recursive: false))
    let (device, storage) = (setup.device, setup.storage)
    await device.onNextDelete {
      try? await device.seed(
        try path("/Reports/late.txt"), in: storage, contents: Data("late".utf8))
    }

    let reply = await setup.send(
      .delete(
        domain: setup.domain, id: try await setup.id("/Reports"), base: nil, recursive: false))

    #expect(reply == .failure(.directoryNotEmpty(try path("/Reports"))))
    #expect(try await setup.known("/Reports/late.txt"))
  }

  /// Past the walk's depth limit the delete is refused, and what the walk found unseen before
  /// that is still recorded.
  @Test func aTooDeepTreeStillRecordsWhatItFoundUnseen() async throws {
    let deep = (1...(RemotePath.maxTreeDepth + 1)).map { "d\($0)" }
    let file = "/" + (deep + ["leaf.txt"]).joined(separator: "/")
    let setup = try await setup([(file, "leaf")])
    defer { setup.harness.finish() }
    let folders = deep.indices.map { "/" + deep[...$0].joined(separator: "/") }
    try await setup.show(["/"] + folders)
    try await setup.device.seed(
      try path("/d1/unseen.txt"), in: setup.storage, contents: Data("new".utf8))

    let reply = await setup.send(
      .delete(domain: setup.domain, id: try await setup.id("/d1"), base: nil, recursive: true))

    #expect(reply == .failure(.directoryNotEmpty(try path("/d1"))))
    #expect(try await setup.known("/d1/unseen.txt"))
  }

  /// The kind `changeable` has to read from the device is kept, so the next change does not ask
  /// again.
  @Test func aKindReadFromTheDeviceIsRecorded() async throws {
    let setup = try await setup([("/Docs/report.rtfd", "a file")])
    defer { setup.harness.finish() }
    let route = try await setup.harness.controller.route(setup.domain)

    _ = try await route.changeable(try await setup.id("/Docs/report.rtfd"))

    #expect(await route.items.kind(at: try path("/Docs/report.rtfd")) == .file)
    await route.release()
  }
}
