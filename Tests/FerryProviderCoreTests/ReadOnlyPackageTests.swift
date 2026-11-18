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
    #expect(try item(path, kind: kind).capabilities == [.allowsReading])
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
}
