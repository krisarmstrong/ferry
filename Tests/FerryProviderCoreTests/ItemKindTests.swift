import DeviceKit
import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

/// Packages are folders on the device; symbolic links and aliases have no contents MTP can
/// store, so they are refused for good with a message that says so.
struct ItemKindTests {
  @Test(arguments: [
    (UTType.folder, ItemTemplate.Kind.folder),
    (UTType("com.apple.rtfd")!, .package),
    (UTType.package, .package),
    (UTType.applicationBundle, .folder),
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

  /// A document package goes to the agent as one archive, made whole on the device.
  @Test func aPackageIsCreatedWhole() async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let package = try localPackage("rtf", in: dir)

    let made = try await backend.create(
      try ItemTemplate(
        Template(
          parent: .rootContainer, filename: "Notes.rtfd", contentType: UTType("com.apple.rtfd")!)),
      contents: package)

    #expect(
      await agent.requests == [.createPackage(domain: domain, parent: .root, name: "Notes.rtfd")])
    #expect(made.contentType == UTType("com.apple.rtfd"))
    let sent = try await extracted(agent.packages[try path("/Notes.rtfd")], in: dir)
    #expect(try Data(contentsOf: sent.appending(path: "TXT.rtf")) == Data("rtf".utf8))
    #expect(try Data(contentsOf: sent.appending(path: "Media/a.png")) == Data("png".utf8))
  }

  /// An edit of a document package replaces it whole.
  @Test func aPackageEditReplacesItWhole() async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let template = try ItemTemplate(
      Template(
        parent: .rootContainer, filename: "Notes.rtfd", contentType: UTType("com.apple.rtfd")!))
    let made = try await backend.create(template, contents: try localPackage("old", in: dir))
    let edited = dir.appending(path: "edited")
    try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: false)

    _ = try await backend.modify(
      made.itemIdentifier, to: template, changed: .contents,
      contents: try localPackage("new", in: edited))

    #expect(
      await agent.requests.last
        == .replacePackage(domain: domain, id: try #require(ItemID(made.itemIdentifier))))
    let sent = try await extracted(agent.packages[try path("/Notes.rtfd")], in: dir)
    #expect(try Data(contentsOf: sent.appending(path: "TXT.rtf")) == Data("new".utf8))
  }

  /// A fetched document package is a folder holding all of it, as FileProvider places it.
  @Test func aPackageIsFetchedAsAFolder() async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let made = try await backend.create(
      try ItemTemplate(
        Template(
          parent: .rootContainer, filename: "Notes.rtfd", contentType: UTType("com.apple.rtfd")!)),
      contents: try localPackage("rtf", in: dir))
    let fetchDir = dir.appending(path: "fetch")
    try FileManager.default.createDirectory(at: fetchDir, withIntermediateDirectories: false)

    let (url, item) = try await backend.fetch(made.itemIdentifier, into: fetchDir)

    var isFolder: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder))
    #expect(isFolder.boolValue)
    #expect(try Data(contentsOf: url.appending(path: "TXT.rtf")) == Data("rtf".utf8))
    #expect(try Data(contentsOf: url.appending(path: "Media/a.png")) == Data("png".utf8))
    #expect(item.contentType == UTType("com.apple.rtfd"))
    // Everything in it is marked as downloaded from the device, as the package itself is.
    let expected = try #require(item.extendedAttributes["com.apple.quarantine"])
    for inside in ["", "TXT.rtf", "Media", "Media/a.png"] {
      let target = inside.isEmpty ? url : url.appending(path: inside)
      var value = [UInt8](repeating: 0, count: 256)
      let length = getxattr(target.path, "com.apple.quarantine", &value, value.count, 0, 0)
      #expect(length > 0, "\(inside)")
      #expect(Data(value.prefix(max(length, 0))) == expected, "\(inside)")
    }
    // Only the folder is left: the archive it came in is gone.
    #expect(try FileManager.default.contentsOfDirectory(atPath: fetchDir.path).count == 1)
  }

  /// A code bundle deeper than the budget is refused, with the description Finder shows.
  @Test func aBundlePastTheBudgetIsRefused() async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(
      domain: domain, client: agent,
      treeBudget: TreeBudget(maxDepth: 0, maxEntries: 100, maxBytes: 1 << 20))
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try localPackage("rtf", in: dir, named: "Plugin.bundle")

    do {
      _ = try await backend.create(
        try ItemTemplate(
          Template(parent: .rootContainer, filename: "Plugin.bundle", contentType: .bundle)),
        contents: bundle)
      Issue.record("the bundle was copied")
    } catch {
      let error = error as NSError
      #expect(error.domain == NSCocoaErrorDomain)
      #expect(error.code == CocoaError.Code.fileReadTooLarge.rawValue)
    }
  }

  /// A code bundle (shown as a folder, see `ProviderItem.contentType`) comes with its folder as
  /// the contents: everything in it goes to the device, links aside.
  @Test func aBundlesContentsAreCopiedIntoItsFolder() async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let package = try localPackage("rtf", in: dir, named: "Plugin.bundle")
    try FileManager.default.createSymbolicLink(
      at: package.appending(path: "link"), withDestinationURL: package.appending(path: "TXT.rtf"))
    let template = try ItemTemplate(
      Template(parent: .rootContainer, filename: "Plugin.bundle", contentType: .bundle))

    _ = try await backend.create(template, contents: package)

    #expect(await agent.contents[try path("/Plugin.bundle/TXT.rtf")] == Data("rtf".utf8))
    #expect(await agent.contents[try path("/Plugin.bundle/Media/a.png")] == Data("png".utf8))
    #expect(await agent.items[try path("/Plugin.bundle/link")] == nil)
  }

  /// Editing a code bundle already on the device: FileProvider sends the package with its folder
  /// as the new contents. The device folder is brought in line: changed and new files go up,
  /// files no longer in the package go.
  @Test func aBundleEditUpdatesTheDeviceFolder() async throws {
    let agent = FakeAgent(
      [
        try folder("/Plugin.bundle"), try file("/Plugin.bundle/TXT.rtf", size: 3),
        try file("/Plugin.bundle/old.png", size: 3), try file("/Plugin.bundle/same.png", size: 4),
      ],
      contents: [
        try path("/Plugin.bundle/TXT.rtf"): Data("old".utf8),
        try path("/Plugin.bundle/old.png"): Data("old".utf8),
        try path("/Plugin.bundle/same.png"): Data("same".utf8),
      ])
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let package = dir.appending(path: "Plugin.bundle", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: package.appending(path: "Media"), withIntermediateDirectories: true)
    try Data("edited".utf8).write(to: package.appending(path: "TXT.rtf"))
    try Data("png".utf8).write(to: package.appending(path: "Media/a.png"))
    let same = package.appending(path: "same.png")
    try Data("same".utf8).write(to: same)
    try FileManager.default.setAttributes(
      [.modificationDate: epoch.addingTimeInterval(-60)], ofItemAtPath: same.path)
    let id = try await agent.identifier(try path("/Plugin.bundle"))

    let item = try await backend.modify(
      id, to: ItemTemplate(parent: .root, filename: "Plugin.bundle", kind: .folder),
      changed: .contents, contents: package)

    #expect(item.itemIdentifier == id)
    #expect(await agent.contents[try path("/Plugin.bundle/TXT.rtf")] == Data("edited".utf8))
    #expect(await agent.contents[try path("/Plugin.bundle/Media/a.png")] == Data("png".utf8))
    #expect(await agent.items[try path("/Plugin.bundle/old.png")] == nil)
    // Unchanged since the device's copy was made: not sent again.
    let replaced = await agent.requests.filter {
      if case .replaceContents = $0 { return true }
      return false
    }
    #expect(replaced.count == 1)
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

  @Test func aFolderCarriesNone() throws {
    let item = ProviderItem(
      ProviderEntry(id: .random(), parent: .root, item: try folder("/DCIM")))
    #expect(item.extendedAttributes.isEmpty)
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

/// A create FileProvider marks "may already exist" matches the device's own copy instead of
/// colliding with it.
struct MayAlreadyExistTests {
  @Test func theSameFileIsMatched() async throws {
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    let agent = FakeAgent([try file("/a.txt", size: 5, modified: modified)])
    let backend = ProviderBackend(domain: domain, client: agent)
    let template = ItemTemplate(
      parent: .root, filename: "a.txt", kind: .file, size: 5,
      modified: modified.addingTimeInterval(0.4))

    let match = try await backend.existing(matching: template)

    #expect(match?.itemIdentifier == (try await agent.identifier(try path("/a.txt"))))
  }

  @Test(arguments: [(UInt64(6), 0.0), (5, 1.0)])
  func aDifferentFileIsNotMatched(size: UInt64, shift: Double) async throws {
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    let agent = FakeAgent([try file("/a.txt", size: 5, modified: modified)])
    let backend = ProviderBackend(domain: domain, client: agent)
    let template = ItemTemplate(
      parent: .root, filename: "a.txt", kind: .file, size: size,
      modified: modified.addingTimeInterval(shift))

    #expect(try await backend.existing(matching: template) == nil)
  }

  @Test func aFolderMatchesAFolderOfTheSameName() async throws {
    let agent = FakeAgent([try folder("/DCIM")])
    let backend = ProviderBackend(domain: domain, client: agent)

    let match = try await backend.existing(
      matching: ItemTemplate(parent: .root, filename: "DCIM", kind: .folder))

    #expect(match?.itemIdentifier == (try await agent.identifier(try path("/DCIM"))))
    #expect(
      try await backend.existing(
        matching: ItemTemplate(
          parent: .root, filename: "DCIM", kind: .file, size: 0, modified: epoch))
        == nil)
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

/// The tree in a package archive the fake agent received, extracted into a new folder.
func extracted(_ archive: Data?, in folder: URL) throws -> URL {
  let file = folder.appending(path: "archive-\(UUID().uuidString)")
  try (archive ?? Data()).write(to: file)
  let reader = try FileHandle(forReadingFrom: file)
  defer { try? reader.close() }
  let out = folder.appending(path: "extracted-\(UUID().uuidString)")
  try PackageArchive.extract(from: reader, to: out)
  return out
}
