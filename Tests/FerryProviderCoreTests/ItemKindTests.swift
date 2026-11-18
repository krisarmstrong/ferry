import DeviceKit
import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

/// Ferry copies files and plain folders. A package (a document such as an `.rtfd`, or an app or
/// other code bundle) is refused for good with one message, and so are symbolic links and
/// aliases, which have no contents MTP can store. On the device every folder is a plain folder.
struct ItemKindTests {
  @Test(arguments: [
    (UTType.folder, ItemTemplate.Kind.folder),
    (UTType("com.apple.rtfd")!, .package),
    (UTType("com.apple.iwork.keynote.key")!, .package),
    (UTType.package, .package),
    (UTType.applicationBundle, .package),
    (UTType.bundle, .package),
    (UTType.pluginBundle, .package),
    (UTType.framework, .package),
    (UTType.applicationExtension, .package),
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

  /// Copied with `cp -R`, a package's folder can first arrive as a plain folder; its name still
  /// makes it a package.
  @Test(arguments: ["Tool.app", "Plugin.bundle", "Kit.framework", "Notes.rtfd", "Talk.key"])
  func aFolderNamedLikeAPackageIsOne(name: String) throws {
    let template = try ItemTemplate(
      Template(parent: .rootContainer, filename: name, contentType: .folder))
    #expect(template.kind == .package)
    #expect(
      try ItemTemplate(Template(parent: .rootContainer, filename: "DCIM", contentType: .folder))
        .kind == .folder)
  }

  /// Documents and code alike: FileProvider treats a package as one item where the device
  /// would hold a folder, so it is refused for good with the one message, and nothing is sent.
  @Test(arguments: [
    ("Notes.rtfd", UTType("com.apple.rtfd")!), ("Talk.key", UTType("com.apple.iwork.keynote.key")!),
    ("Ferry.app", UTType.applicationBundle), ("Plugin.bundle", UTType.bundle),
    ("Viewer.plugin", UTType.pluginBundle), ("Share.appex", UTType.applicationExtension),
    ("Copied.rtfd", UTType.folder),
  ])
  func aPackageIsRefusedForGoodWithTheZipMessage(name: String, type: UTType) async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let package = try localPackage("text", in: dir, named: name)

    do {
      _ = try await backend.create(
        try ItemTemplate(Template(parent: .rootContainer, filename: name, contentType: type)),
        contents: package)
      Issue.record("the package was copied")
    } catch {
      let error = error as NSError
      #expect(error.domain == NSFileProviderErrorDomain)
      #expect(error.code == NSFileProviderError.Code.cannotSynchronize.rawValue)
      #expect(
        error.localizedDescription
          == "Packages and app bundles can’t be copied to the device. Compress it into a .zip first."
      )
    }
    #expect(await agent.requests.isEmpty)
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

  /// Whatever its name, Ferry presents a device folder as a plain folder.
  @Test(arguments: [
    "Notes.rtfd", "Talk.key", "Ferry.app", "x.bundle", "x.plugin", "x.appex",
    "x.systemextension", "x.kext", "x.scptd", "x.pkg", "com.foo.app", "DCIM", "report.txt",
  ])
  func aDeviceFolderIsAlwaysAPlainFolder(name: String) throws {
    #expect(try deviceFolder(name).contentType == .folder)
  }
}

private func deviceFolder(_ name: String) throws -> ProviderItem {
  ProviderItem(
    ProviderEntry(
      id: .random(), parent: .root,
      item: RemoteItem(path: try path("/" + name), kind: .folder, size: 0, modified: epoch)))
}

/// Contents from a USB device are untrusted downloads: Gatekeeper checks an app or script from
/// one before it runs.
struct QuarantineTests {
  @Test func aFileFromTheDeviceCarriesTheQuarantine() throws {
    let id = ItemID.random()
    let item = ProviderItem(
      ProviderEntry(
        id: id, parent: .root,
        item: RemoteItem(
          path: try path("/run.command"), kind: .file, size: 2,
          modified: Date(timeIntervalSince1970: 0x6553_F100))))

    let value = try #require(item.extendedAttributes["com.apple.quarantine"])

    #expect(String(bytes: value, encoding: .utf8) == "0083;6553f100;Ferry;\(id.rawValue)")
  }

  /// macOS types a folder by its name's extension whatever Ferry presents, so a device folder
  /// named like a package shows in Finder as a document or an app. It is quarantined too, so
  /// Gatekeeper checks such an app as a download.
  @Test(arguments: ["Ferry.app", "Notes.rtfd", "Talk.key", "x.plugin", "x.appex"])
  func aFolderNamedLikeAPackageCarriesTheQuarantine(name: String) throws {
    let item = try deviceFolder(name)
    let value = try #require(item.extendedAttributes["com.apple.quarantine"])
    #expect(String(bytes: value, encoding: .utf8)?.hasPrefix("0083;") == true)
  }

  @Test(arguments: ["DCIM", "report.txt", "Android", "x.unknownext"])
  func aPlainFolderCarriesNone(name: String) throws {
    #expect(try deviceFolder(name).extendedAttributes.isEmpty)
  }
}

/// Finder's progress for a copy counts the bytes the agent reports.
struct FileProgressTests {
  @Test func aFetchMovesItsProgressInBytes() async throws {
    let agent = FakeAgent([try file("/big.bin", size: 8)])
    await agent.set(progressTotal: 8)
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (progress, update) = FileProgress.make(.downloading)
    let seen = Mutex<[Int64]>([])

    _ = try await backend.fetch(
      try await agent.identifier(try path("/big.bin")), into: dir,
      progress: { completed, total in
        update(completed, total)
        seen.withLock { $0.append(progress.completedUnitCount) }
      })

    #expect(seen.withLock { $0 } == [4, 8])
    #expect(progress.totalUnitCount == 8)
    #expect(progress.kind == .file)
    #expect(progress.fileOperationKind == .downloading)
  }
}

struct FileProgressOverflowTests {
  /// A device-reported size past `Int64.max` clamps rather than traps.
  @Test func hugeSizesClamp() {
    let (progress, update) = FileProgress.make(.uploading)
    update(UInt64.max, UInt64.max)
    #expect(progress.totalUnitCount == Int64.max)
    #expect(progress.completedUnitCount == Int64.max)
  }
}

/// A local package `named` holding `TXT.rtf` (`text`) and `Media/a.png`, in `folder`.
func localPackage(_ text: String, in folder: URL, named name: String = "Notes.rtfd") throws -> URL {
  let package = folder.appending(path: name, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(
    at: package.appending(path: "Media"), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: package.appending(path: "TXT.rtf"))
  try Data("png".utf8).write(to: package.appending(path: "Media/a.png"))
  return package
}
