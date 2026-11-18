import CoreServices
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

  /// Only document packages: a folder named like an app, plug-in or other bundle stays a
  /// folder, so Finder never offers code from a USB device as something to launch.
  @Test(arguments: [
    ("Notes.rtfd", "com.apple.rtfd"), ("Talk.key", "com.apple.iwork.keynote.key"),
    ("Ferry.app", "public.folder"), ("x.bundle", "public.folder"),
    ("x.plugin", "public.folder"), ("x.appex", "public.folder"),
    ("x.systemextension", "public.folder"), ("x.kext", "public.folder"),
    ("x.scptd", "public.folder"), ("x.pkg", "public.folder"),
    ("DCIM", "public.folder"), ("report.txt", "public.folder"),
  ])
  func aDeviceFolderNamedLikeADocumentPackageIsOne(name: String, identifier: String) throws {
    let item = ProviderItem(
      ProviderEntry(
        id: .random(), parent: .root,
        item: RemoteItem(path: try path("/" + name), kind: .folder, size: 0, modified: epoch)))
    #expect(item.contentType.identifier == identifier)
  }
}

/// Contents from a USB device are untrusted downloads: Gatekeeper checks an app or script from
/// one before it runs.
struct FetchQuarantineTests {
  @Test func aFetchedFileIsQuarantined() async throws {
    let agent = FakeAgent(
      [try file("/run.command", size: 2)], contents: [try path("/run.command"): Data("hi".utf8)])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (url, _) = try await backend.fetch(
      try await agent.identifier(try path("/run.command")), into: dir)

    let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
    #expect(size > 0)
    let properties = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
      .quarantineProperties
    #expect(properties?[kLSQuarantineAgentNameKey as String] as? String == "Ferry")
  }
}
