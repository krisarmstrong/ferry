import DeviceKit
import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite struct ProviderBackendTests {
  @Test func rootMapsToRootContainer() async throws {
    let backend = ProviderBackend(domain: domain, client: FakeAgent())
    let root = try await backend.item(.rootContainer)
    #expect(root.itemIdentifier == .rootContainer)
    #expect(root.parentItemIdentifier == .rootContainer)
    #expect(root.contentType == .folder)
    #expect(root.capabilities.contains(.allowsAddingSubItems))
    #expect(root.capabilities.contains(.allowsContentEnumerating))
    #expect(!root.capabilities.contains(.allowsRenaming))
    #expect(!root.capabilities.contains(.allowsReparenting))
    #expect(!root.capabilities.contains(.allowsDeleting))
  }

  @Test func childrenBuildItemsWithIdentifiers() async throws {
    let agent = FakeAgent([
      try folder("/DCIM"), try file("/DCIM/a.jpg", size: 3), try file("/notes.txt"),
    ])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dcim = try await agent.identifier(try path("/DCIM"))

    let top = try await backend.children(of: .rootContainer)
    #expect(top.map(\.filename) == ["DCIM", "notes.txt"])
    #expect(
      top.map(\.itemIdentifier)
        == [dcim, try await agent.identifier(try path("/notes.txt"))])
    #expect(top.allSatisfy { $0.parentItemIdentifier == .rootContainer })
    #expect(top[0].contentType == .folder)
    #expect(top[0].capabilities.contains(.allowsAddingSubItems))
    #expect(top[1].capabilities.contains(.allowsDeleting))

    let nested = try await backend.children(of: dcim)
    #expect(nested.map(\.itemIdentifier) == [try await agent.identifier(try path("/DCIM/a.jpg"))])
    #expect(nested[0].parentItemIdentifier == dcim)
    #expect(nested[0].filename == "a.jpg")
    #expect(nested[0].documentSize == 3)
    #expect(nested[0].contentType == .jpeg)
    #expect(
      await agent.requests.last
        == .list(domain: domain, folder: try await agent.id(try path("/DCIM"))))
  }

  @Test func unknownContainersAreNoSuchItem() async throws {
    let backend = ProviderBackend(domain: domain, client: FakeAgent())
    // A path, as identifiers once were, and the root's own raw value name nothing either.
    let junk: [NSFileProviderItemIdentifier] = [
      .trashContainer, .workingSet, .init("relative"), .init("/DCIM"), .init(ItemID.root.rawValue),
    ]
    for id in junk {
      await #expect(throws: NSFileProviderError(.noSuchItem)) { try await backend.item(id) }
    }
    #expect(try await backend.children(of: .workingSet).isEmpty)
  }

  @Test func fetchReturnsFileInDir() async throws {
    let bytes = Data("hello".utf8)
    let agent = FakeAgent(
      [try file("/a.txt", size: 5)], contents: [try path("/a.txt"): bytes])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    let id = try await agent.id(try path("/a.txt"))

    let (url, item) = try await backend.fetch(NSFileProviderItemIdentifier(id), into: dir)
    #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(item.itemIdentifier == NSFileProviderItemIdentifier(id))
    // The item is read before the bytes: a newer file under an older version gets fetched again.
    #expect(
      await agent.requests == [.item(domain: domain, id: id), .fetch(domain: domain, id: id)])
  }

  @Test func failedFetchLeavesNoFile() async throws {
    let agent = FakeAgent(
      [try file("/a.txt", size: 5)], contents: [try path("/a.txt"): Data("hello".utf8)])
    await agent.set(fetchFailure: .deviceDisconnected)
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()

    await #expect(throws: NSFileProviderError(.serverUnreachable)) {
      try await backend.fetch(try await agent.identifier(try path("/a.txt")), into: dir)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
  }

  @Test func createFileAndFolder() async throws {
    let agent = FakeAgent([try folder("/DCIM")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    let upload = try writeContents(Data("abc".utf8), in: dir)
    let dcim = try await agent.id(try path("/DCIM"))

    let made = try await backend.create(
      ItemTemplate(parent: dcim, filename: "a.txt", isFolder: false), contents: upload)
    #expect(made.itemIdentifier == (try await agent.identifier(try path("/DCIM/a.txt"))))
    #expect(made.parentItemIdentifier == NSFileProviderItemIdentifier(dcim))
    #expect(made.documentSize == 3)
    #expect(await agent.contents[try path("/DCIM/a.txt")] == Data("abc".utf8))

    let folder = try await backend.create(
      ItemTemplate(parent: .root, filename: "Music", isFolder: true), contents: nil)
    #expect(folder.itemIdentifier == (try await agent.identifier(try path("/Music"))))
    #expect(folder.contentType == .folder)
    #expect(
      await agent.requests == [
        .create(domain: domain, parent: dcim, name: "a.txt", isFolder: false),
        .create(domain: domain, parent: .root, name: "Music", isFolder: true),
      ])
  }

  @Test func createFileWithoutContentsIsRejected() async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    await #expect(throws: CocoaError.self) {
      try await backend.create(
        ItemTemplate(parent: .root, filename: "a", isFolder: false), contents: nil)
    }
    #expect(await agent.requests.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func concurrentCreatesAllLand() async throws {
    let agent = FakeAgent()
    // Every create waits for all twenty, so a backend that sent them one at a time would hang.
    await agent.park(until: 20)
    let backend = ProviderBackend(domain: domain, client: agent)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<20 {
        group.addTask {
          _ = try await backend.create(
            ItemTemplate(parent: .root, filename: "f\(index)", isFolder: true), contents: nil)
        }
      }
      try await group.waitForAll()
    }
    let created = await agent.items.keys.compactMap(\.name)
    #expect(Set(created) == Set((0..<20).map { "f\($0)" }))
  }

  @Test func modifyRenameMoveAndContentsInOrder() async throws {
    let agent = FakeAgent([try folder("/Docs"), try file("/a.txt", size: 1)])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    let upload = try writeContents(Data("new!".utf8), in: dir)
    let (id, docs) = (try await agent.id(try path("/a.txt")), try await agent.id(try path("/Docs")))

    let changed = try await backend.modify(
      NSFileProviderItemIdentifier(id),
      to: ItemTemplate(parent: docs, filename: "b.txt", isFolder: false),
      changed: ItemChanges([.parentItemIdentifier, .filename, .contents, .lastUsedDate]),
      contents: upload)

    #expect(changed.itemIdentifier == NSFileProviderItemIdentifier(id))
    #expect(changed.filename == "b.txt")
    #expect(changed.documentSize == 4)
    #expect(
      await agent.requests == [
        .item(domain: domain, id: id),
        .move(domain: domain, id: id, toFolder: docs),
        .rename(domain: domain, id: id, to: "b.txt"),
        .replaceContents(domain: domain, id: id),
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
      to: ItemTemplate(parent: .root, filename: "e\u{301}.txt", isFolder: false),
      changed: ItemChanges([.parentItemIdentifier, .filename, .lastUsedDate]), contents: nil)
    #expect(item.itemIdentifier == NSFileProviderItemIdentifier(id))
    #expect(await agent.requests == [.item(domain: domain, id: id)])
  }

  @Test func caseOnlyRenameSucceeds() async throws {
    let agent = FakeAgent([try file("/readme.txt"), try file("/other.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)

    let id = try await agent.identifier(try path("/readme.txt"))

    let renamed = try await backend.modify(
      id, to: ItemTemplate(parent: .root, filename: "README.txt", isFolder: false),
      changed: .filename, contents: nil)
    #expect(renamed.filename == "README.txt")
    #expect(renamed.itemIdentifier == id)

    await #expect(throws: NSFileProviderError(.filenameCollision)) {
      try await backend.modify(
        id, to: ItemTemplate(parent: .root, filename: "OTHER.txt", isFolder: false),
        changed: .filename, contents: nil)
    }
  }

  @Test func deleteSendsDelete() async throws {
    let agent = FakeAgent([try file("/a.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let id = try await agent.id(try path("/a.txt"))
    try await backend.delete(NSFileProviderItemIdentifier(id))
    #expect(await agent.requests == [.delete(domain: domain, id: id)])
    await #expect(throws: NSFileProviderError(.noSuchItem)) {
      try await backend.delete(NSFileProviderItemIdentifier(id))
    }
  }

  @Test func disconnectedMapsToServerUnreachable() async throws {
    let agent = FakeAgent([try file("/a.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)

    let id = try await agent.identifier(try path("/a.txt"))
    await agent.set(failure: .deviceDisconnected)
    await #expect(throws: NSFileProviderError(.serverUnreachable)) {
      try await backend.item(id)
    }
    // AgentClient throws this itself when the connection to the agent is lost.
    await agent.set(failure: nil, thrown: .deviceDisconnected)
    await #expect(throws: NSFileProviderError(.serverUnreachable)) {
      try await backend.children(of: .rootContainer)
    }
  }

  @Test func versionChangesWhenSizeOrDateChanges() throws {
    let (id, parent) = (ItemID.random(), ItemID.random())
    func version(_ item: RemoteItem, in folder: ItemID? = nil) -> NSFileProviderItemVersion {
      ProviderItem(ProviderEntry(id: id, parent: folder ?? parent, item: item)).itemVersion
    }
    let base = version(try file("/a.txt", size: 1))
    let same = version(try file("/a.txt", size: 1))
    let resized = version(try file("/a.txt", size: 2))
    let touched = version(try file("/a.txt", size: 1, modified: epoch + 1))
    let renamed = version(try file("/b.txt", size: 1))
    let moved = version(try file("/a.txt", size: 1), in: .random())

    #expect(base.contentVersion == same.contentVersion)
    #expect(base.metadataVersion == same.metadataVersion)
    #expect(base.contentVersion != resized.contentVersion)
    #expect(base.contentVersion != touched.contentVersion)
    #expect(base.contentVersion == renamed.contentVersion)
    #expect(base.metadataVersion != renamed.metadataVersion)
    #expect(base.metadataVersion != moved.metadataVersion)
  }

  @Test func modifyReturnsSameIdentifier() async throws {
    let agent = FakeAgent([try folder("/Docs"), try file("/a.txt", size: 1)])
    let backend = ProviderBackend(domain: domain, client: agent)
    let id = try await agent.identifier(try path("/a.txt"))
    let docs = try await agent.id(try path("/Docs"))

    let changed = try await backend.modify(
      id, to: ItemTemplate(parent: docs, filename: "b.txt", isFolder: false),
      changed: [.parent, .filename], contents: nil)

    #expect(changed.itemIdentifier == id)
    #expect(changed.parentItemIdentifier == NSFileProviderItemIdentifier(docs.rawValue))
    #expect(changed.filename == "b.txt")
  }

  @Test func templateIsSendableSnapshot() async throws {
    let agent = FakeAgent([try folder("/Docs")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let docs = try await agent.identifier(try path("/Docs"))
    let item: any NSFileProviderItem = Template(parent: docs, filename: "Sub", contentType: .folder)

    // The extension's callback shape: snapshot synchronously, then hand only Sendable values to
    // the task.
    let template = try ItemTemplate(item)
    let made = try await Task { try await backend.create(template, contents: nil) }.value

    #expect(
      template == ItemTemplate(parent: try #require(ItemID(docs)), filename: "Sub", isFolder: true))
    #expect(made.parentItemIdentifier == docs)
    #expect(try ItemTemplate(Template(parent: .rootContainer, filename: "f")).parent == .root)
    #expect(throws: NSFileProviderError(.noSuchItem)) {
      try ItemTemplate(Template(parent: .trashContainer, filename: "f"))
    }
  }
}
