import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Deletes and content replacements that FileProvider sends from what it last saw: a folder it
/// thought empty, a file the device has changed since. The device's newer content always wins
/// over a stale request; nothing on the device is lost.
@Suite(.timeLimit(.minutes(1)))
struct AgentDeleteAndConflictTests {
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

    /// The version FileProvider holds for the item, from the agent's own report of it.
    func version(_ string: String) async throws -> ContentVersion {
      guard case .entry(let entry) = await send(.item(domain: domain, id: try await id(string)))
      else { throw TransportError.unknownItem }
      return ContentVersion(entry.item)
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

  // MARK: Folders (C1)

  @Test func aNonRecursiveDeleteOfAFolderWithFilesIsRefused() async throws {
    let setup = try await setup([("/Reports/r1.txt", "one"), ("/Reports/r2.txt", "two")])
    defer { setup.harness.finish() }
    let reports = try await setup.id("/Reports")

    let reply = await setup.send(
      .delete(domain: setup.domain, id: reports, base: nil, recursive: false))

    #expect(reply == .failure(.directoryNotEmpty(try path("/Reports"))))
    #expect(await setup.device.contents(of: try path("/Reports/r1.txt"), in: setup.storage) != nil)
    #expect(await setup.device.contents(of: try path("/Reports/r2.txt"), in: setup.storage) != nil)
  }

  @Test func aNonRecursiveDeleteOfAnEmptyFolderDeletesIt() async throws {
    let setup = try await setup([("/Reports/r1.txt", "one")])
    defer { setup.harness.finish() }
    let file = try await setup.id("/Reports/r1.txt")
    let reports = try await setup.id("/Reports")
    #expect(
      await setup.send(.delete(domain: setup.domain, id: file, base: nil, recursive: false))
        == .done)

    #expect(
      await setup.send(.delete(domain: setup.domain, id: reports, base: nil, recursive: false))
        == .done)
    #expect(await setup.device.contents(of: try path("/Reports"), in: setup.storage) == nil)
    #expect(
      await setup.send(.list(domain: setup.domain, folder: .root)) == .entries([]))
  }

  /// A partial an earlier upload abandoned is invisible, so the folder looks empty in Finder and
  /// must delete; the listing that checks reaps the partial.
  @Test func aFolderHoldingOnlyAnAbandonedPartialDeletes() async throws {
    let setup = try await setup([("/Empty/\(SafeWriter.partialPrefix)stale", "par")])
    defer { setup.harness.finish() }
    let empty = try await setup.id("/Empty")

    #expect(
      await setup.send(.delete(domain: setup.domain, id: empty, base: nil, recursive: false))
        == .done)
  }

  /// Deleted on the device since Finder last saw it: the delete succeeds and the item is
  /// forgotten.
  @Test func deletingAFileAlreadyGoneFromTheDeviceSucceeds() async throws {
    let setup = try await setup([("/a.txt", "old")])
    defer { setup.harness.finish() }
    let file = try await setup.id("/a.txt")
    try await setup.device.delete(try path("/a.txt"), in: setup.storage)

    #expect(
      await setup.send(.delete(domain: setup.domain, id: file, base: nil, recursive: false))
        == .done)
    #expect(await setup.send(.item(domain: setup.domain, id: file)) == .failure(.unknownItem))
  }

  // MARK: Base versions (I1)

  @Test func deletingAFileTheDeviceChangedSinceIsRejected() async throws {
    let setup = try await setup([("/a.txt", "old")])
    defer { setup.harness.finish() }
    let file = try await setup.id("/a.txt")
    let base = try await setup.version("/a.txt")
    try await setup.device.seed(try path("/a.txt"), in: setup.storage, contents: Data("newer".utf8))

    let reply = await setup.send(
      .delete(domain: setup.domain, id: file, base: base, recursive: false))

    #expect(reply == .failure(.changedOnDevice(try path("/a.txt"))))
    #expect(
      await setup.device.contents(of: try path("/a.txt"), in: setup.storage) == Data("newer".utf8))
    // The device's file is recorded, so FileProvider puts back that version.
    guard
      case .page(let entries, _) = await setup.send(
        .workingSet(domain: setup.domain, page: nil))
    else { throw TransportError.unknownItem }
    #expect(entries.first { $0.id == file }?.item.size == 5)
  }

  @Test func deletingAFileAtItsBaseVersionDeletesIt() async throws {
    let setup = try await setup([("/a.txt", "old")])
    defer { setup.harness.finish() }
    let file = try await setup.id("/a.txt")
    let base = try await setup.version("/a.txt")

    #expect(
      await setup.send(.delete(domain: setup.domain, id: file, base: base, recursive: false))
        == .done)
    #expect(await setup.device.contents(of: try path("/a.txt"), in: setup.storage) == nil)
  }

  @Test func replacingAFileTheDeviceChangedKeepsBoth() async throws {
    let setup = try await setup([("/Docs/report.txt", "old")])
    defer { setup.harness.finish() }
    let file = try await setup.id("/Docs/report.txt")
    let base = try await setup.version("/Docs/report.txt")
    try await setup.device.seed(
      try path("/Docs/report.txt"), in: setup.storage, contents: Data("from the unit".utf8))
    let mac = try setup.harness.readable("mac.txt", "from the mac")

    let reply = await setup.send(
      .replaceContents(domain: setup.domain, id: file, base: base, onConflict: .keepBoth),
      file: mac)

    // The device's item, flagged as kept: FileProvider must fetch it, not keep the Mac's bytes.
    guard case .keptOnDevice(let entry) = reply else {
      Issue.record("expected the device's item, kept, got \(reply)")
      return
    }
    #expect(entry.id == file)
    #expect(entry.item.size == UInt64("from the unit".utf8.count))
    #expect(
      await setup.device.contents(of: try path("/Docs/report.txt"), in: setup.storage)
        == Data("from the unit".utf8))
    #expect(
      await setup.device.contents(
        of: try path("/Docs/report (conflict from Mac).txt"), in: setup.storage)
        == Data("from the mac".utf8))
  }

  @Test func aConflictCopyTakesTheNextFreeName() async throws {
    let setup = try await setup([
      ("/report.txt", "old"), ("/report (conflict from Mac).txt", "an earlier conflict"),
    ])
    defer { setup.harness.finish() }
    let file = try await setup.id("/report.txt")
    let base = try await setup.version("/report.txt")
    try await setup.device.seed(
      try path("/report.txt"), in: setup.storage, contents: Data("u".utf8))

    let reply = await setup.send(
      .replaceContents(domain: setup.domain, id: file, base: base, onConflict: .keepBoth),
      file: try setup.harness.readable("mac.txt", "mac"))

    guard case .keptOnDevice = reply else {
      Issue.record("expected the device's item, kept, got \(reply)")
      return
    }
    #expect(
      await setup.device.contents(
        of: try path("/report (conflict from Mac 2).txt"), in: setup.storage) == Data("mac".utf8))
    #expect(
      await setup.device.contents(
        of: try path("/report (conflict from Mac).txt"), in: setup.storage)
        == Data("an earlier conflict".utf8))
  }

  @Test func replacingAChangedFileFailsWhenAskedTo() async throws {
    let setup = try await setup([("/a.txt", "old")])
    defer { setup.harness.finish() }
    let file = try await setup.id("/a.txt")
    let base = try await setup.version("/a.txt")
    try await setup.device.seed(try path("/a.txt"), in: setup.storage, contents: Data("unit".utf8))

    let reply = await setup.send(
      .replaceContents(domain: setup.domain, id: file, base: base, onConflict: .fail),
      file: try setup.harness.readable("mac.txt", "mac"))

    #expect(reply == .failure(.changedOnDevice(try path("/a.txt"))))
    #expect(
      await setup.device.contents(of: try path("/a.txt"), in: setup.storage) == Data("unit".utf8))
  }

  /// Saving twice in a row: the second save's base is the version the first one returned.
  @Test func replacingAtTheReturnedVersionTwiceIsNoConflict() async throws {
    let setup = try await setup([("/a.txt", "old")])
    defer { setup.harness.finish() }
    let file = try await setup.id("/a.txt")
    var base = try await setup.version("/a.txt")
    for text in ["first save", "second save"] {
      let reply = await setup.send(
        .replaceContents(domain: setup.domain, id: file, base: base, onConflict: .keepBoth),
        file: try setup.harness.readable("\(text).txt", text))
      guard case .entry(let entry) = reply else {
        Issue.record("expected an entry, got \(reply)")
        return
      }
      base = ContentVersion(entry.item)
    }
    #expect(
      await setup.device.contents(of: try path("/a.txt"), in: setup.storage)
        == Data("second save".utf8))
    #expect(
      await setup.send(.list(domain: setup.domain, folder: .root)).entryNames == ["a.txt"])
  }

  // MARK: Stale listed sizes (round 8 C1)

  /// A device whose metadata is stale lists `global.o` as 32 bytes and sends 40. FileProvider
  /// holds the version of the 40 bytes it received, and sends that as the base.
  private func fetchedStale() async throws -> (Setup, ProviderEntry) {
    let setup = try await setup([])
    let file = try path("/Docs/global.o")
    try await setup.device.seed(file, in: setup.storage, contents: Data(count: 40))
    await setup.device.reportSize(32, for: file)
    let id = try await setup.id("/Docs/global.o")
    let (_, handle) = try setup.harness.writable("out", "")
    guard
      case .entry(let entry) = await setup.send(.fetch(domain: setup.domain, id: id), file: handle)
    else { throw TransportError.unknownItem }
    #expect(entry.item.size == 40)
    return (setup, entry)
  }

  @Test func deletingAFileWithAStaleListedSizeAtItsFetchedVersionDeletesIt() async throws {
    let (setup, fetched) = try await fetchedStale()
    defer { setup.harness.finish() }
    let (id, base) = (fetched.id, ContentVersion(fetched.item))

    let reply = await setup.send(
      .delete(domain: setup.domain, id: id, base: base, recursive: false))

    #expect(reply == .done)
    #expect(await setup.device.contents(of: try path("/Docs/global.o"), in: setup.storage) == nil)
  }

  @Test func savingAFileWithAStaleListedSizeAtItsFetchedVersionIsNoConflict() async throws {
    let (setup, fetched) = try await fetchedStale()
    defer { setup.harness.finish() }
    let (id, base) = (fetched.id, ContentVersion(fetched.item))

    let reply = await setup.send(
      .replaceContents(domain: setup.domain, id: id, base: base, onConflict: .keepBoth),
      file: try setup.harness.readable("mac.o", "user edit"))

    #expect(reply.isEntry)
    #expect(
      await setup.device.contents(of: try path("/Docs/global.o"), in: setup.storage)
        == Data("user edit".utf8))
    #expect(
      await setup.device.contents(
        of: try path("/Docs/global (conflict from Mac).o"), in: setup.storage) == nil)
  }

  @Test(arguments: [
    ("report.txt", 1, "report (conflict from Mac).txt"),
    ("report.txt", 3, "report (conflict from Mac 3).txt"),
    ("README", 1, "README (conflict from Mac)"),
    ("archive.tar.gz", 1, "archive.tar (conflict from Mac).gz"),
    (".profile", 1, ".profile (conflict from Mac)"),
  ])
  func conflictNames(name: String, attempt: Int, expected: String) {
    #expect(ConflictCopy.name(for: name, attempt: attempt) == expected)
  }

}

extension AgentDeleteAndConflictTests {
  // MARK: Changed during the upload (round 10)

  /// The device's file passed the save's base check, then an app on the device replaced it
  /// while the Mac's contents went up.
  @Test(arguments: [ConflictPolicy.keepBoth, .fail])
  func aFileTheDeviceReplacesDuringTheSaveIsKept(policy: ConflictPolicy) async throws {
    let setup = try await setup([("/a.txt", "old")])
    defer { setup.harness.finish() }
    let file = try await setup.id("/a.txt")
    let base = try await setup.version("/a.txt")
    let (device, storage) = (setup.device, setup.storage)
    await device.onNextUpload {
      try? await device.seed(try path("/a.txt"), in: storage, contents: Data("unit edit".utf8))
    }

    let reply = await setup.send(
      .replaceContents(domain: setup.domain, id: file, base: base, onConflict: policy),
      file: try setup.harness.readable("mac.txt", "mac"))

    #expect(await device.contents(of: try path("/a.txt"), in: storage) == Data("unit edit".utf8))
    let copy = await device.contents(of: try path("/a (conflict from Mac).txt"), in: storage)
    switch policy {
    case .keepBoth:
      guard case .keptOnDevice(let entry) = reply else {
        Issue.record("expected the device's item, kept, got \(reply)")
        return
      }
      #expect(entry.item.size == 9)
      #expect(copy == Data("mac".utf8))
    case .fail:
      #expect(reply == .failure(.changedOnDevice(try path("/a.txt"))))
      #expect(copy == nil)
    }
  }
}

extension AgentResponse {
  fileprivate var entryNames: [String] {
    guard case .entries(let entries) = self else { return [] }
    return entries.compactMap(\.item.path.name)
  }
}
