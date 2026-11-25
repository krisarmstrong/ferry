import DeviceKit
import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Testing

/// A modify applies the changed fields in order, keeps the item's identifier, and tells
/// FileProvider to fetch the contents again only when they are not the ones it sent.
struct ProviderModifyTests {
  @Test func modifyRenameMoveAndContentsInOrder() async throws {
    let agent = FakeAgent([try folder("/Docs"), try file("/a.txt", size: 1)])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    let upload = try writeContents(Data("new!".utf8), in: dir)
    let (id, docs) = (try await agent.id(try path("/a.txt")), try await agent.id(try path("/Docs")))

    let changed = try await backend.modify(
      NSFileProviderItemIdentifier(id),
      to: ItemTemplate(parent: docs, filename: "b.txt", kind: .file),
      changed: ItemChanges([.parentItemIdentifier, .filename, .contents, .lastUsedDate]),
      contents: upload
    ).item

    #expect(changed.itemIdentifier == NSFileProviderItemIdentifier(id))
    #expect(changed.filename == "b.txt")
    #expect(changed.documentSize == 4)
    #expect(
      await agent.requests == [
        .item(domain: domain, id: id),
        .move(domain: domain, id: id, toFolder: docs),
        .rename(domain: domain, id: id, to: "b.txt"),
        .replaceContents(domain: domain, id: id, base: nil, onConflict: .keepBoth),
      ])
    #expect(await agent.contents[try path("/Docs/b.txt")] == Data("new!".utf8))
  }

  @Test func modifyIgnoresUnchangedFields() async throws {
    let agent = FakeAgent([try file("/\u{E9}.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)

    let id = try await agent.id(try path("/\u{E9}.txt"))
    // Finder may report a filename change with the name it already has, in another normal form.
    let item = try await backend.modify(
      NSFileProviderItemIdentifier(id),
      to: ItemTemplate(parent: .root, filename: "e\u{301}.txt", kind: .file),
      changed: ItemChanges([.parentItemIdentifier, .filename, .lastUsedDate]), contents: nil
    ).item
    #expect(item.itemIdentifier == NSFileProviderItemIdentifier(id))
    #expect(await agent.requests == [.item(domain: domain, id: id)])
  }

  @Test func caseOnlyRenameSucceeds() async throws {
    let agent = FakeAgent([try file("/readme.txt"), try file("/other.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)

    let id = try await agent.identifier(try path("/readme.txt"))

    let renamed = try await backend.modify(
      id, to: ItemTemplate(parent: .root, filename: "README.txt", kind: .file),
      changed: .filename, contents: nil
    ).item
    #expect(renamed.filename == "README.txt")
    #expect(renamed.itemIdentifier == id)

    await #expect(throws: NSFileProviderError(.filenameCollision)) {
      try await backend.modify(
        id, to: ItemTemplate(parent: .root, filename: "OTHER.txt", kind: .file),
        changed: .filename, contents: nil)
    }
  }

  /// The device changed the file since the save's base, so the agent kept the device's version
  /// and put the Mac's beside it. FileProvider must fetch the device's contents, or the Mac's
  /// next save would overwrite the device's edit.
  @Test func aSaveTheDeviceKeptAsksFileProviderToFetchIt() async throws {
    let agent = FakeAgent(
      [try file("/a.txt", size: 1)], contents: [try path("/a.txt"): Data("d".utf8)])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = try await agent.identifier(try path("/a.txt"))
    await agent.keepDeviceVersionOnNextSave()

    let saved = try await backend.modify(
      id, to: ItemTemplate(parent: .root, filename: "a.txt", kind: .file), changed: .contents,
      contents: try writeContents(Data("from the mac".utf8), in: dir))

    #expect(saved.shouldFetchContent)
    #expect(saved.item.itemIdentifier == id)
    #expect(saved.item.documentSize == 1)
  }

  @Test func aSaveThatWentUpNeedsNoFetch() async throws {
    let agent = FakeAgent([try file("/a.txt", size: 1)])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = try await agent.identifier(try path("/a.txt"))

    let saved = try await backend.modify(
      id, to: ItemTemplate(parent: .root, filename: "a.txt", kind: .file), changed: .contents,
      contents: try writeContents(Data("from the mac".utf8), in: dir))

    #expect(!saved.shouldFetchContent)
    #expect(saved.item.documentSize == 12)
  }

  /// A save of a file the device does not have (made while it was away, or whose identifier the
  /// agent lost) is "no such item", never a create under a new identifier, which a modify must
  /// not return. FileProvider then re-creates the item, local edits included, through createItem
  /// (`NSFileProviderReplicatedExtension.h`, modifyItem's error cases), which uploads it.
  @Test func aSaveOfAnUnknownFileIsNoSuchItemAndItsCreateUploadsIt() async throws {
    let agent = FakeAgent([try folder("/Docs")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let docs = try await agent.id(try path("/Docs"))
    let template = ItemTemplate(parent: docs, filename: "new.txt", kind: .file)
    let edited = try writeContents(Data("made offline".utf8), in: dir)

    await #expect(throws: NSFileProviderError(.noSuchItem)) {
      try await backend.modify(
        NSFileProviderItemIdentifier(ItemID.random()), to: template, changed: .contents,
        contents: edited)
    }
    #expect(await agent.requests.allSatisfy { if case .create = $0 { false } else { true } })

    let created = try await backend.create(template, contents: edited, mayAlreadyExist: false)
    #expect(created?.item.filename == "new.txt")
    #expect(await agent.contents[try path("/Docs/new.txt")] == Data("made offline".utf8))
  }
}
