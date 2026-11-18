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

  /// FileProvider deletes a package as one item, without the recursive option: its folder on
  /// the device goes with what is inside it.
  @Test func aPackageDeletesWithItsContents() async throws {
    let setup = try await setup([("/Notes.rtfd/TXT.rtf", "rtf")])
    defer { setup.harness.finish() }
    let package = try await setup.id("/Notes.rtfd")

    #expect(
      await setup.send(.delete(domain: setup.domain, id: package, base: nil, recursive: false))
        == .done)
    #expect(
      await setup.device.contents(of: try path("/Notes.rtfd/TXT.rtf"), in: setup.storage) == nil)
  }

  @Test func aRecursiveDeleteRemovesTheFolderAndItsFiles() async throws {
    let setup = try await setup([("/Reports/r1.txt", "one"), ("/Reports/Sub/r2.txt", "two")])
    defer { setup.harness.finish() }
    let reports = try await setup.id("/Reports")

    #expect(
      await setup.send(.delete(domain: setup.domain, id: reports, base: nil, recursive: true))
        == .done)
    #expect(await setup.device.contents(of: try path("/Reports/r1.txt"), in: setup.storage) == nil)
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

    guard case .entry(let entry) = reply else {
      Issue.record("expected the device's item, got \(reply)")
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

    guard case .entry = reply else {
      Issue.record("expected the device's item, got \(reply)")
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

extension AgentResponse {
  fileprivate var entryNames: [String] {
    guard case .entries(let entries) = self else { return [] }
    return entries.compactMap(\.item.path.name)
  }
}
