import DeviceKit
import Foundation

// MARK: Names on the device

/// Ferry's paths are NFC (`RemotePath`), but the device compares names byte for byte, and a
/// name may be stored in another form (NFD, as macOS and some apps write it). MTP reaches such
/// a file by its object ID; here every listing records how the device spells each name, keyed by
/// the folder's device path, and every path sent to the device is spelled that way. A name no
/// listing has recorded (a new item, or one Ferry created) goes as given.
///
/// Two spellings of one name are one path to Ferry. As `MTPSession` keeps one object of a
/// duplicated name, one is kept: the one spelled in NFC, whose bytes are its path; else the
/// first listed. The other is left out like any name Ferry cannot use, so a checked delete of
/// its folder is refused.
///
/// A recorded spelling can go stale when another app renames a folder: the path then fails as
/// not found until its parent is listed again, which every write and every exact-name check does.
extension ADBSession {
  /// What a folder holds that Ferry can address, and how many entries it left out.
  struct Children {
    var items: [RemoteItem] = []
    var skipped = 0
  }

  /// The folder at `path`, listed fresh, its spellings recorded. A missing path or a file is
  /// `.notFound`: the sync service answers both with an empty listing. Without `exactSizes` a
  /// file over 4 GB on a device without `ls_v2` reports its size modulo 4 GB; name checks do
  /// not read sizes, and skip a STA2 per file.
  ///
  /// Left out, as MTPSession leaves out names it cannot use: a name that is not UTF-8, one whose
  /// device path is too long for the sync service, the second spelling of a name, and anything
  /// that is neither a file nor a folder.
  func children(of folder: RemotePath, under root: String, exactSizes: Bool = true)
    async throws(TransportError) -> Children
  {
    let location = try await location(of: folder, under: root)
    guard try await stat(at: location, as: folder)?.kind == .folder else {
      throw .notFound(folder)
    }
    let listing = try await adb(Step("listing", folder)) { () async throws(ADBError) in
      try await syncing { (sync) async throws(ADBError) in
        try await sync.list(location, exactSizes: exactSizes)
      }
    }
    var skipped = listing.unreadableNames
    var kept: [RemotePath: (spelling: String, item: RemoteItem)] = [:]
    for entry in listing.entries {
      guard let path = try? folder.appending(entry.name),
        (location + "/" + entry.name).utf8.count <= ADBSync.requestLimit,
        let item = Self.item(entry.stat, at: path)
      else {
        skipped += 1
        continue
      }
      guard let twin = kept[path] else {
        kept[path] = (entry.name, item)
        continue
      }
      skipped += 1
      if Self.isSpelled(path, entry.name), !Self.isSpelled(path, twin.spelling) {
        kept[path] = (entry.name, item)
      }
    }
    rawNames[Array(location.utf8)] = Dictionary(
      uniqueKeysWithValues: kept.map { ($0.key.name ?? "", $0.value.spelling) })
    if skipped > 0 {
      Self.log.info("listing left out \(skipped) entries Ferry cannot address")
    }
    return Children(items: kept.values.map(\.item), skipped: skipped)
  }

  /// Whether `spelling` is the very bytes of `path`'s name.
  private static func isSpelled(_ path: RemotePath, _ spelling: String) -> Bool {
    path.name?.utf8.elementsEqual(spelling.utf8) == true
  }

  /// `path` as the device spells it. A folder on the way that no listing has recorded is listed
  /// (names only); one that does not exist leaves the rest of the path as given.
  func location(of path: RemotePath, under root: String) async throws(TransportError) -> String {
    var location = root
    var folder = RemotePath.root
    for name in path.components {
      if rawNames[Array(location.utf8)] == nil {
        do throws(TransportError) {
          _ = try await children(of: folder, under: root, exactSizes: false)
        } catch .notFound {}
      }
      location += "/" + (rawNames[Array(location.utf8)]?[name] ?? name)
      folder = try folder.appending(name)
    }
    return location
  }

  /// The item at `path` and where it is on the device. `path` must be listed in its folder
  /// under exactly that name: storage that ignores case would otherwise act on `A.txt` when asked
  /// for `a.txt`. The listing is fresh, so the spelling used is current.
  ///
  /// Only the last name is held to this. Folders on the way resolve as the device resolves
  /// them, so after another app changes a folder's case `/Foo/x` reaches `/foo/x`, where MTP
  /// would say not found. On case-insensitive storage that is the same file.
  func existing(_ path: RemotePath, under root: String) async throws(TransportError)
    -> (item: RemoteItem, location: String)
  {
    guard let parent = path.parent else { throw .notFound(path) }
    let siblings: Children
    do throws(TransportError) {
      siblings = try await children(of: parent, under: root, exactSizes: false)
    } catch .notFound {
      throw .notFound(path)
    }
    guard siblings.items.contains(where: { $0.path == path }) else { throw .notFound(path) }
    let location = try await location(of: path, under: root)
    guard let item = try await stat(at: location, as: path) else { throw .notFound(path) }
    return (item, location)
  }

  /// The item at device path `location`, reported as `path`; `nil` if there is none (or it is
  /// neither file nor folder).
  func stat(at location: String, as path: RemotePath) async throws(TransportError)
    -> RemoteItem?
  {
    let stat = try await adb(Step("reading", path)) { () async throws(ADBError) in
      try await syncing { (sync) async throws(ADBError) in try await sync.stat(location) }
    }
    return stat.flatMap { Self.item($0, at: path) }
  }

  /// Drops the recorded spellings of the folder at `location` and of everything in it, after it
  /// or what it holds changed.
  func forget(_ location: String) {
    let key = Array(location.utf8)
    let inside = key + [UInt8(ascii: "/")]
    rawNames = rawNames.filter { $0.key != key && !$0.key.starts(with: inside) }
  }

  /// The last name in `location`, as the device spells it.
  static func lastName(_ location: String) -> String {
    guard let slash = location.utf8.lastIndex(of: UInt8(ascii: "/")) else { return location }
    return String(location[location.utf8.index(after: slash)...])
  }

  static func parentLocation(_ location: String) -> String {
    // By bytes: a name starting with a combining mark joins its slash into one `Character`.
    guard let slash = location.utf8.lastIndex(of: UInt8(ascii: "/")) else { return location }
    return String(location[..<slash])
  }
}
