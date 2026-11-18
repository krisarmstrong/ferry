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

  @Test func childrenBuildItemsWithPaths() async throws {
    let agent = FakeAgent([
      try folder("/DCIM"), try file("/DCIM/a.jpg", size: 3), try file("/notes.txt"),
    ])
    let backend = ProviderBackend(domain: domain, client: agent)

    let top = try await backend.children(of: .rootContainer).sorted { $0.filename < $1.filename }
    #expect(top.map(\.itemIdentifier.rawValue) == ["/DCIM", "/notes.txt"])
    #expect(top.allSatisfy { $0.parentItemIdentifier == .rootContainer })
    #expect(top[0].contentType == .folder)
    #expect(top[0].capabilities.contains(.allowsAddingSubItems))
    #expect(top[1].capabilities.contains(.allowsDeleting))

    let nested = try await backend.children(of: NSFileProviderItemIdentifier("/DCIM"))
    #expect(nested.map(\.itemIdentifier.rawValue) == ["/DCIM/a.jpg"])
    #expect(nested[0].parentItemIdentifier.rawValue == "/DCIM")
    #expect(nested[0].filename == "a.jpg")
    #expect(nested[0].documentSize == 3)
    #expect(nested[0].contentType == .jpeg)
    #expect(await agent.requests.last == .list(domain: domain, folder: try path("/DCIM")))
  }

  @Test func unknownContainersAreNoSuchItem() async throws {
    let backend = ProviderBackend(domain: domain, client: FakeAgent())
    for id in [NSFileProviderItemIdentifier.trashContainer, .workingSet, .init("relative")] {
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

    let (url, item) = try await backend.fetch(NSFileProviderItemIdentifier("/a.txt"), into: dir)
    #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(item.itemIdentifier.rawValue == "/a.txt")
    // The item is read before the bytes: a newer file under an older version gets fetched again.
    #expect(
      await agent.requests == [
        .item(domain: domain, path: try path("/a.txt")),
        .fetch(domain: domain, path: try path("/a.txt")),
      ])
  }

  @Test func failedFetchLeavesNoFile() async throws {
    let agent = FakeAgent(
      [try file("/a.txt", size: 5)], contents: [try path("/a.txt"): Data("hello".utf8)])
    await agent.set(fetchFailure: .deviceDisconnected)
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()

    await #expect(throws: NSFileProviderError(.serverUnreachable)) {
      try await backend.fetch(NSFileProviderItemIdentifier("/a.txt"), into: dir)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
  }

  @Test func createFileAndFolder() async throws {
    let agent = FakeAgent([try folder("/DCIM")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    let upload = try writeContents(Data("abc".utf8), in: dir)

    let made = try await backend.create(
      Template(parent: NSFileProviderItemIdentifier("/DCIM"), filename: "a.txt"),
      contents: upload)
    #expect(made.itemIdentifier.rawValue == "/DCIM/a.txt")
    #expect(made.documentSize == 3)
    #expect(await agent.contents[try path("/DCIM/a.txt")] == Data("abc".utf8))

    let folder = try await backend.create(
      Template(parent: .rootContainer, filename: "Music", contentType: .folder), contents: nil)
    #expect(folder.itemIdentifier.rawValue == "/Music")
    #expect(folder.contentType == .folder)
    #expect(
      await agent.requests == [
        .create(domain: domain, path: try path("/DCIM/a.txt"), isFolder: false),
        .create(domain: domain, path: try path("/Music"), isFolder: true),
      ])
  }

  @Test func createFileWithoutContentsIsRejected() async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    await #expect(throws: CocoaError.self) {
      try await backend.create(Template(parent: .rootContainer, filename: "a"), contents: nil)
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
            Template(parent: .rootContainer, filename: "f\(index)", contentType: .folder),
            contents: nil)
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

    let changed = try await backend.modify(
      Template(id: "/a.txt", parent: NSFileProviderItemIdentifier("/Docs"), filename: "b.txt"),
      changed: [.parentItemIdentifier, .filename, .contents], contents: upload)

    #expect(changed.itemIdentifier.rawValue == "/Docs/b.txt")
    #expect(changed.documentSize == 4)
    #expect(
      await agent.requests == [
        .move(domain: domain, path: try path("/a.txt"), toFolder: try path("/Docs")),
        .rename(domain: domain, path: try path("/Docs/a.txt"), to: "b.txt"),
        .replaceContents(domain: domain, path: try path("/Docs/b.txt")),
      ])
  }

  @Test func modifyIgnoresUnchangedFields() async throws {
    let agent = FakeAgent([try file("/\u{E9}.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)

    // Finder may report a filename change with the name it already has, in another normal form.
    let item = try await backend.modify(
      Template(id: "/\u{E9}.txt", parent: .rootContainer, filename: "e\u{301}.txt"),
      changed: [.parentItemIdentifier, .filename, .lastUsedDate], contents: nil)
    #expect(item.itemIdentifier.rawValue == "/\u{E9}.txt")
    #expect(await agent.requests == [.item(domain: domain, path: try path("/\u{E9}.txt"))])
  }

  @Test func caseOnlyRenameSucceeds() async throws {
    let agent = FakeAgent([try file("/readme.txt"), try file("/other.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)

    let renamed = try await backend.modify(
      Template(id: "/readme.txt", parent: .rootContainer, filename: "README.txt"),
      changed: .filename, contents: nil)
    #expect(renamed.itemIdentifier.rawValue == "/README.txt")

    await #expect(throws: NSFileProviderError(.filenameCollision)) {
      try await backend.modify(
        Template(id: "/README.txt", parent: .rootContainer, filename: "OTHER.txt"),
        changed: .filename, contents: nil)
    }
  }

  @Test func deleteSendsDelete() async throws {
    let agent = FakeAgent([try file("/a.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)
    try await backend.delete(NSFileProviderItemIdentifier("/a.txt"))
    #expect(await agent.requests == [.delete(domain: domain, path: try path("/a.txt"))])
    await #expect(throws: NSFileProviderError(.noSuchItem)) {
      try await backend.delete(NSFileProviderItemIdentifier("/a.txt"))
    }
  }

  @Test func disconnectedMapsToServerUnreachable() async throws {
    let agent = FakeAgent([try file("/a.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)

    await agent.set(failure: .deviceDisconnected)
    await #expect(throws: NSFileProviderError(.serverUnreachable)) {
      try await backend.item(NSFileProviderItemIdentifier("/a.txt"))
    }
    // AgentClient throws this itself when the connection to the agent is lost.
    await agent.set(failure: nil, thrown: .deviceDisconnected)
    await #expect(throws: NSFileProviderError(.serverUnreachable)) {
      try await backend.children(of: .rootContainer)
    }
  }

  @Test func everyTransportErrorMaps() throws {
    let samples: [TransportError] = [
      .noDeviceConnected, .deviceNotFound(DeviceID(serial: "S1")), .noStorage,
      .storageNotFound("SD card"), .deviceBusy, .deviceLocked, .deviceDisconnected,
      .notFound(try path("/a")), .alreadyExists(try path("/a")), .invalidName("a/b"),
      .unsupported("copy"), .insufficientSpace(needed: 2, free: 1),
      .fileTooLargeForStorage(size: 5), .sizeMismatch(expected: 2, actual: 1),
      .nameChangedByDevice(requested: "Résumé.txt", actual: "RESUME.TXT"), .cancelled,
      .io("pipe broke"),
    ]
    for sample in samples {
      let mapped = ErrorMapping.fileProviderError(sample) as NSError
      switch expected(sample) {
      case .fileProvider(let code):
        #expect(mapped.domain == NSFileProviderErrorDomain, "\(sample)")
        #expect(mapped.code == code.rawValue, "\(sample)")
      case .cocoa(let code):
        #expect(mapped.domain == NSCocoaErrorDomain, "\(sample)")
        #expect(mapped.code == code.rawValue, "\(sample)")
      case .described(let fragments):
        #expect(mapped.domain == ErrorMapping.domain, "\(sample)")
        for fragment in fragments {
          #expect(mapped.localizedDescription.contains(fragment), "\(sample)")
        }
      }
    }
  }

  private enum Expected {
    case fileProvider(NSFileProviderError.Code)
    case cocoa(CocoaError.Code)
    case described([String])
  }

  /// No `default`: a new `TransportError` case must be given an expectation here.
  private func expected(_ error: TransportError) -> Expected {
    switch error {
    case .noDeviceConnected, .noStorage, .deviceBusy, .deviceDisconnected:
      .fileProvider(.serverUnreachable)
    case .deviceLocked: .fileProvider(.notAuthenticated)
    case .notFound, .storageNotFound: .fileProvider(.noSuchItem)
    case .alreadyExists: .fileProvider(.filenameCollision)
    case .insufficientSpace, .fileTooLargeForStorage: .fileProvider(.insufficientQuota)
    case .invalidName: .cocoa(.fileWriteInvalidFileName)
    case .cancelled: .cocoa(.userCancelled)
    case .nameChangedByDevice(let requested, let actual): .described([requested, actual])
    case .deviceNotFound(let id): .described([id.serial])
    case .unsupported(let what): .described([what])
    case .sizeMismatch: .described(["2", "1"])
    case .io(let message): .described([message])
    }
  }

  @Test func versionChangesWhenSizeOrDateChanges() throws {
    let base = ProviderItem(try file("/a.txt", size: 1)).itemVersion
    let same = ProviderItem(try file("/a.txt", size: 1)).itemVersion
    let resized = ProviderItem(try file("/a.txt", size: 2)).itemVersion
    let touched = ProviderItem(try file("/a.txt", size: 1, modified: epoch + 1)).itemVersion
    let renamed = ProviderItem(try file("/b.txt", size: 1)).itemVersion

    #expect(base.contentVersion == same.contentVersion)
    #expect(base.metadataVersion == same.metadataVersion)
    #expect(base.contentVersion != resized.contentVersion)
    #expect(base.contentVersion != touched.contentVersion)
    #expect(base.contentVersion == renamed.contentVersion)
    #expect(base.metadataVersion != renamed.metadataVersion)
  }
}
