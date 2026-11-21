import DeviceKit
import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Testing

/// A create FileProvider marks "may already exist" (an import after it lost its state, or a
/// merge) matches the device's item of that name and kind instead of colliding with it. A
/// matched file whose version differs from the Mac's is the device's: FileProvider fetches it.
struct MayAlreadyExistTests {
  private let modified = Date(timeIntervalSince1970: 1_700_000_000)

  private func importing(
    _ template: ItemTemplate, from agent: FakeAgent, contents: URL? = nil
  ) async throws -> SyncedItem? {
    try await ProviderBackend(domain: domain, client: agent).create(
      template, contents: contents, mayAlreadyExist: true)
  }

  @Test func theSameFileIsMatchedWithoutAFetch() async throws {
    let agent = FakeAgent([try file("/a.txt", size: 5, modified: modified)])
    let template = ItemTemplate(
      parent: .root, filename: "a.txt", kind: .file, size: 5,
      modified: modified.addingTimeInterval(0.4))

    let match = try #require(try await importing(template, from: agent))

    #expect(match.item.itemIdentifier == (try await agent.identifier(try path("/a.txt"))))
    #expect(!match.shouldFetchContent)
    #expect(await agent.requests == [.list(domain: domain, folder: .root)])
  }

  /// A listing that expired part-way starts again from its first page, so the create does not
  /// fail with an enumeration error (W5 review M5).
  @Test func anExpiredListingIsListedAgain() async throws {
    let agent = FakeAgent([try file("/a.txt", size: 5, modified: modified)])
    await agent.expireTheNextList()
    let template = ItemTemplate(
      parent: .root, filename: "a.txt", kind: .file, size: 5, modified: modified)

    #expect(try await importing(template, from: agent) != nil)
    #expect(
      await agent.requests == [
        .list(domain: domain, folder: .root), .list(domain: domain, folder: .root),
      ])
  }

  @Test(arguments: [(UInt64?(6), 0.0), (5, 1.0), (nil, 0.0)])
  func aFileThatDiffersIsMatchedAndFetched(size: UInt64?, shift: Double) async throws {
    let agent = FakeAgent([try file("/a.txt", size: 5, modified: modified)])
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let template = ItemTemplate(
      parent: .root, filename: "a.txt", kind: .file, size: size,
      modified: modified.addingTimeInterval(shift))

    let match = try #require(
      try await importing(
        template, from: agent, contents: try writeContents(Data("mac!!!".utf8), in: dir)))

    #expect(match.item.itemIdentifier == (try await agent.identifier(try path("/a.txt"))))
    #expect(match.shouldFetchContent)
    #expect(await agent.requests == [.list(domain: domain, folder: .root)])
  }

  /// After FileProvider lost its state, a folder the device holds under a package's name is
  /// still matched, so re-importing it never puts the package refusal on the device's own folder.
  @Test func aPackageNamedTemplateMatchesTheDeviceFolderOfTheSameName() async throws {
    let agent = FakeAgent([try folder("/Notes.rtfd")])

    let match = try #require(
      try await importing(
        ItemTemplate(parent: .root, filename: "Notes.rtfd", kind: .package), from: agent))

    #expect(match.item.itemIdentifier == (try await agent.identifier(try path("/Notes.rtfd"))))
    #expect(match.item.contentType == .folder)
    #expect(!match.shouldFetchContent)
  }

  /// A package FileProvider finds on the Mac with nothing of its name on the device is never
  /// answered with no item, which would delete it from the Mac with everything in it: it stays
  /// on the Mac, out of sync.
  @Test(arguments: [false, true])
  func aPackageWithNoDeviceMatchIsExcludedFromSync(withContents: Bool) async throws {
    let agent = FakeAgent()
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let contents = withContents ? try localPackage("text", in: dir) : nil

    await #expect(throws: NSFileProviderError(.excludedFromSync)) {
      _ = try await importing(
        ItemTemplate(parent: .root, filename: "Notes.rtfd", kind: .package), from: agent,
        contents: contents)
    }
    #expect(await agent.requests == [.list(domain: domain, folder: .root)])
  }

  @Test func aFolderMatchesAFolderOfTheSameNameButNotAFile() async throws {
    let agent = FakeAgent([try folder("/DCIM")])

    let match = try #require(
      try await importing(ItemTemplate(parent: .root, filename: "DCIM", kind: .folder), from: agent)
    )

    #expect(match.item.itemIdentifier == (try await agent.identifier(try path("/DCIM"))))
    #expect(!match.shouldFetchContent)
    // A file of that name, with no contents on the Mac, has nothing to create.
    #expect(
      try await importing(
        ItemTemplate(parent: .root, filename: "DCIM", kind: .file, size: 0, modified: epoch),
        from: agent) == nil)
  }

  @Test func withNoMatchTheFileIsCreated() async throws {
    let agent = FakeAgent()
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let made = try #require(
      try await importing(
        ItemTemplate(parent: .root, filename: "new.txt", kind: .file, size: 3, modified: epoch),
        from: agent, contents: try writeContents(Data("new".utf8), in: dir)))

    #expect(!made.shouldFetchContent)
    #expect(await agent.contents[try path("/new.txt")] == Data("new".utf8))
  }
}
