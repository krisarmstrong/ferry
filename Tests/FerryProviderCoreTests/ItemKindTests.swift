import DeviceKit
import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Testing
import UniformTypeIdentifiers

/// Packages are folders on the device; symbolic links and aliases have no contents MTP can
/// store, so they are refused for good with a message that says so.
struct ItemKindTests {
  @Test(arguments: [
    (UTType.folder, ItemTemplate.Kind.folder),
    (UTType("com.apple.rtfd")!, .folder),
    (UTType.applicationBundle, .folder),
    (UTType.package, .folder),
    (UTType.bundle, .folder),
    (UTType.symbolicLink, .link),
    (UTType.aliasFile, .link),
    (UTType.data, .file),
    (UTType.jpeg, .file),
  ])
  func kindFollowsTheContentType(type: UTType, kind: ItemTemplate.Kind) throws {
    let template = try ItemTemplate(
      Template(parent: .rootContainer, filename: "x", contentType: type))
    #expect(template.kind == kind)
  }

  @Test func aPackageIsCreatedAsAFolder() async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    let template = try ItemTemplate(
      Template(
        parent: .rootContainer, filename: "Notes.rtfd", contentType: UTType("com.apple.rtfd")!))

    let made = try await backend.create(template, contents: nil)

    #expect(
      await agent.requests == [
        .create(domain: domain, parent: .root, name: "Notes.rtfd", isFolder: true)
      ])
    #expect(made.contentType == UTType("com.apple.rtfd"))
  }

  @Test(arguments: [UTType.symbolicLink, UTType.aliasFile])
  func aLinkIsRefusedForGoodWithAMessage(type: UTType) async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    let template = try ItemTemplate(
      Template(parent: .rootContainer, filename: "link", contentType: type))
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // An alias is a file with contents, so contents alone do not make it uploadable.
    let contents = try writeContents(Data("bookmark".utf8), in: dir)

    do {
      _ = try await backend.create(template, contents: contents)
      Issue.record("the link was created")
    } catch {
      let error = error as NSError
      #expect(error.domain == NSFileProviderErrorDomain)
      #expect(error.code == NSFileProviderError.Code.cannotSynchronize.rawValue)
      #expect(error.localizedDescription.contains("aliases"))
    }
    #expect(await agent.requests.isEmpty)
  }

  @Test(arguments: [
    ("Notes.rtfd", "com.apple.rtfd"), ("Ferry.app", "com.apple.application-bundle"),
    ("DCIM", "public.folder"), ("report.txt", "public.folder"),
  ])
  func aDeviceFolderNamedLikeAPackageIsOne(name: String, identifier: String) throws {
    let item = ProviderItem(
      ProviderEntry(
        id: .random(), parent: .root,
        item: RemoteItem(path: try path("/" + name), kind: .folder, size: 0, modified: epoch)))
    #expect(item.contentType.identifier == identifier)
  }
}
