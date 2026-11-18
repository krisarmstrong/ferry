import DeviceKit
import Foundation
import Testing

@testable import MTPTransport

/// Serves a fixed tree keyed by parent ID and counts how often it is asked.
actor StubLister {
  private let tree: [UInt32: [MTPEntry]]
  private(set) var calls: [UInt32] = []

  init(_ tree: [UInt32: [MTPEntry]]) {
    self.tree = tree
  }

  func list(storage: UInt32, parent: UInt32) -> [MTPEntry] {
    calls.append(parent)
    return tree[parent] ?? []
  }
}

/// Serves a fixed tree but holds the first listing of `held` open until released, to race an
/// invalidation against it.
actor GatedLister {
  private let tree: [UInt32: [MTPEntry]]
  private var held: UInt32?
  private var gate: CheckedContinuation<Void, Never>?
  private(set) var calls: [UInt32] = []

  init(_ tree: [UInt32: [MTPEntry]], holding held: UInt32) {
    self.tree = tree
    self.held = held
  }

  var isHolding: Bool { gate != nil }

  func list(parent: UInt32) async -> [MTPEntry] {
    calls.append(parent)
    if parent == held {
      held = nil
      await withCheckedContinuation { gate = $0 }
    }
    return tree[parent] ?? []
  }

  func release() {
    gate?.resume()
    gate = nil
  }
}

struct PathResolverTests {
  static let storage: UInt32 = 0x0001_0001
  static let epoch = Date(timeIntervalSince1970: 0)

  static func folder(_ id: UInt32, _ name: String) -> MTPEntry {
    MTPEntry(objectID: id, parent: 0, name: name, isFolder: true, size: 0, modified: epoch)
  }

  static func file(_ id: UInt32, _ name: String) -> MTPEntry {
    MTPEntry(objectID: id, parent: 0, name: name, isFolder: false, size: 1, modified: epoch)
  }

  func makeResolver(_ tree: [UInt32: [MTPEntry]]) -> (PathResolver, StubLister) {
    let stub = StubLister(tree)
    let resolver = PathResolver { storage, parent in
      await stub.list(storage: storage, parent: parent)
    }
    return (resolver, stub)
  }

  var cameraTree: [UInt32: [MTPEntry]] {
    var tree = [PathResolver.rootParent: [Self.folder(10, "DCIM"), Self.file(11, "notes.txt")]]
    tree[10] = [Self.folder(20, "Camera")]
    tree[20] = [Self.file(30, "a.jpg")]
    return tree
  }

  @Test func rootResolvesToRootParent() async throws {
    let (resolver, stub) = makeResolver(cameraTree)
    #expect(
      try await resolver.objectID(for: .root, storage: Self.storage) == PathResolver.rootParent)
    #expect(await stub.calls.isEmpty)
  }

  @Test func resolvesNestedPath() async throws {
    let (resolver, stub) = makeResolver(cameraTree)
    let id = try await resolver.objectID(for: RemotePath("/DCIM/Camera"), storage: Self.storage)
    #expect(id == 20)
    #expect(await stub.calls == [PathResolver.rootParent, 10])
  }

  @Test func cachesListings() async throws {
    let (resolver, stub) = makeResolver(cameraTree)
    let path = try RemotePath("/DCIM/Camera")
    _ = try await resolver.objectID(for: path, storage: Self.storage)
    _ = try await resolver.objectID(for: path, storage: Self.storage)
    #expect(await stub.calls.count == 2)
  }

  @Test func entriesListsFolder() async throws {
    let (resolver, _) = makeResolver(cameraTree)
    let entries = try await resolver.entries(in: RemotePath("/DCIM/Camera"), storage: Self.storage)
    #expect(entries == [Self.file(30, "a.jpg")])
  }

  @Test func invalidateForcesRelist() async throws {
    let (resolver, stub) = makeResolver(cameraTree)
    let dcim = try RemotePath("/DCIM")
    _ = try await resolver.entries(in: dcim, storage: Self.storage)
    await resolver.invalidate(dcim, storage: Self.storage)
    _ = try await resolver.entries(in: dcim, storage: Self.storage)
    #expect(await stub.calls == [PathResolver.rootParent, 10, 10])
  }

  @Test func invalidateDropsDescendants() async throws {
    let (resolver, stub) = makeResolver(cameraTree)
    let camera = try RemotePath("/DCIM/Camera")
    _ = try await resolver.entries(in: camera, storage: Self.storage)
    await resolver.invalidate(try RemotePath("/DCIM"), storage: Self.storage)
    _ = try await resolver.entries(in: camera, storage: Self.storage)
    #expect(await stub.calls == [PathResolver.rootParent, 10, 20, 10, 20])
  }

  @Test func invalidateAllForcesRelist() async throws {
    let (resolver, stub) = makeResolver(cameraTree)
    _ = try await resolver.entries(in: .root, storage: Self.storage)
    await resolver.invalidateAll()
    _ = try await resolver.entries(in: .root, storage: Self.storage)
    #expect(await stub.calls == [PathResolver.rootParent, PathResolver.rootParent])
  }

  /// Lists `folder` while the listing of `held` is gated, invalidating everything mid-flight.
  func resolveAcrossInvalidation(
    _ folder: RemotePath, tree: [UInt32: [MTPEntry]], holding held: UInt32
  ) async throws -> (PathResolver, GatedLister) {
    let lister = GatedLister(tree, holding: held)
    let resolver = PathResolver { _, parent in await lister.list(parent: parent) }
    let first = Task { try await resolver.entries(in: folder, storage: Self.storage) }
    while await !lister.isHolding {
      await Task.yield()
    }
    await resolver.invalidateAll()
    await lister.release()
    _ = try await first.value
    return (resolver, lister)
  }

  @Test func listingInFlightAcrossInvalidationIsNotCached() async throws {
    let (resolver, lister) = try await resolveAcrossInvalidation(
      .root, tree: cameraTree, holding: PathResolver.rootParent)
    _ = try await resolver.entries(in: .root, storage: Self.storage)
    #expect(await lister.calls == [PathResolver.rootParent, PathResolver.rootParent])
  }

  /// An ancestor listed before an invalidation may name an object that has since moved, so the
  /// folder listed through it must not be cached either.
  @Test func ancestorListedAcrossInvalidationDoesNotCacheFolder() async throws {
    let dcim = try RemotePath("/DCIM")
    let (resolver, lister) = try await resolveAcrossInvalidation(
      dcim, tree: cameraTree, holding: PathResolver.rootParent)
    _ = try await resolver.entries(in: dcim, storage: Self.storage)
    #expect(await lister.calls == [PathResolver.rootParent, 10, PathResolver.rootParent, 10])
  }

  @Test func storagesAreCachedSeparately() async throws {
    let (resolver, stub) = makeResolver(cameraTree)
    _ = try await resolver.entries(in: .root, storage: 1)
    _ = try await resolver.entries(in: .root, storage: 2)
    #expect(await stub.calls.count == 2)
  }

  @Test func missingComponentThrowsNotFound() async throws {
    let (resolver, _) = makeResolver(cameraTree)
    let path = try RemotePath("/DCIM/Missing/x.jpg")
    await #expect(throws: TransportError.notFound(path)) {
      _ = try await resolver.objectID(for: path, storage: Self.storage)
    }
  }

  @Test func fileAsIntermediateComponentThrowsNotFound() async throws {
    let (resolver, _) = makeResolver(cameraTree)
    let path = try RemotePath("/notes.txt/inner")
    await #expect(throws: TransportError.notFound(path)) {
      _ = try await resolver.objectID(for: path, storage: Self.storage)
    }
  }

  @Test func duplicateNamesResolveToLowestID() async throws {
    let (resolver, _) = makeResolver([
      PathResolver.rootParent: [Self.file(9, "a"), Self.file(4, "a")]
    ])
    #expect(try await resolver.objectID(for: RemotePath("/a"), storage: Self.storage) == 4)
  }

  @Test func namesMatchNFC() async throws {
    let nfd = "Cafe\u{0301}"
    let (resolver, _) = makeResolver([PathResolver.rootParent: [Self.folder(7, nfd)]])
    let path = try RemotePath("/Caf\u{00E9}")
    #expect(try await resolver.objectID(for: path, storage: Self.storage) == 7)
  }

  @Test func listerErrorPropagates() async throws {
    let resolver = PathResolver { _, _ throws(TransportError) in throw .deviceDisconnected }
    await #expect(throws: TransportError.deviceDisconnected) {
      _ = try await resolver.entries(in: .root, storage: Self.storage)
    }
  }
}
