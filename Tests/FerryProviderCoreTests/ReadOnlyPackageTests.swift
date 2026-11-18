import DeviceKit
import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Testing

/// macOS opens a folder named like a package (`Ferry.app`, `Notes.rtfd`) as an app or a
/// document whatever Ferry presents, and an app saving such a document replaces the whole folder,
/// which Ferry refuses. So such a folder and everything in it are read-only on the Mac, and no
/// folder may be renamed to such a name.
struct ReadOnlyPackageTests {
  private func item(_ string: String, kind: ItemKind = .folder) throws -> ProviderItem {
    ProviderItem(
      ProviderEntry(
        id: .random(), parent: .random(),
        item: RemoteItem(path: try path(string), kind: kind, size: 0, modified: epoch)))
  }

  @Test(arguments: [
    ("/Ferry.app", ItemKind.folder), ("/Ferry.app/Contents", .folder),
    ("/Ferry.app/Contents/MacOS/x", .file), ("/Docs/Notes.rtfd", .folder),
    ("/Docs/Notes.rtfd/TXT.rtf", .file),
  ])
  func aPackageFolderAndWhatItHoldsAreReadOnly(path: String, kind: ItemKind) throws {
    // Evictable still: the device keeps it, and Finder can free the Mac's copy.
    #expect(
      try item(path, kind: kind).capabilities == [.allowsReading, ProviderItem.allowsEvicting])
  }

  @Test(arguments: [
    ("/DCIM", ItemKind.folder), ("/DCIM/a.jpg", .file), ("/Docs/notes.rtfd", .file),
  ])
  func anythingElseCanBeChanged(path: String, kind: ItemKind) throws {
    let capabilities = try item(path, kind: kind).capabilities
    #expect(capabilities.contains([.allowsWriting, .allowsRenaming, .allowsDeleting]))
    #expect(capabilities.contains(.allowsReparenting))
  }

  @Test(arguments: ["Pics.app", "Notes.rtfd"])
  func aFolderIsNotRenamedToAPackageName(name: String) async throws {
    let agent = FakeAgent([try folder("/DCIM")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let id = try await agent.identifier(try path("/DCIM"))

    do {
      _ = try await backend.modify(
        id, to: ItemTemplate(parent: .root, filename: name, kind: .package),
        changed: .filename, contents: nil)
      Issue.record("the folder was renamed")
    } catch {
      let error = error as NSError
      #expect(error.domain == NSFileProviderErrorDomain)
      #expect(error.code == NSFileProviderError.Code.cannotSynchronize.rawValue)
      #expect(error.localizedDescription.contains("package"))
    }
    #expect(!(await agent.requests.contains { if case .rename = $0 { true } else { false } }))
  }

  /// A rename to a package name is refused before anything changes, a move sent with it too.
  @Test func aMoveAndRenameToAPackageNameSendsNothing() async throws {
    let agent = FakeAgent([try folder("/DCIM"), try folder("/Docs")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let id = try await agent.identifier(try path("/DCIM"))
    let docs = try await agent.id(try path("/Docs"))

    await #expect(throws: (any Error).self) {
      _ = try await backend.modify(
        id, to: ItemTemplate(parent: docs, filename: "Pics.app", kind: .package),
        changed: [.parent, .filename], contents: nil)
    }
    #expect(await agent.requests == [.item(domain: domain, id: try #require(ItemID(id)))])
  }

  /// The agent refuses a direct delete of something read-only: FileProvider puts it back.
  @Test func aReadOnlyRefusalOfADeleteIsARejectedDeletion() async throws {
    let agent = FakeAgent([try file("/a.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)
    await agent.set(deleteFailure: .readOnly(try path("/a.txt")))

    do {
      try await backend.delete(try await agent.identifier(try path("/a.txt")))
      Issue.record("the delete succeeded")
    } catch {
      #expect((error as NSError).code == NSFileProviderError.Code.deletionRejected.rawValue)
    }
  }
}
