import CryptoKit
import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ItemTable")

// MARK: Table files

extension ItemTable {
  /// The file holding `domain`'s table.
  static func file(for domain: String, in store: URL) -> URL {
    let digest = SHA256.hash(data: Data(domain.utf8)).map { String(format: "%02x", $0) }.joined()
    return store.appending(path: "\(digest).json", directoryHint: .notDirectory)
  }

  /// The journal of changes made to `domain`'s table since its file was last written.
  static func journal(for domain: String, in store: URL) -> URL {
    file(for: domain, in: store).deletingPathExtension().appendingPathExtension("journal")
  }

  /// Deletes `domain`'s table files, for a domain whose table is not loaded.
  static func discard(domain: String, in store: URL) {
    remove(file(for: domain, in: store))
    remove(journal(for: domain, in: store))
  }

  /// Writes `value` to `file` atomically; returns the bytes written.
  static func write(_ value: some Encodable, to file: URL) throws -> Int {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(value)
    try data.write(to: file, options: .atomic)
    return data.count
  }

  /// Appends `value` to `file` as one line, in one write, so a torn write can only spoil the
  /// last line; returns the bytes written.
  static func append(_ value: some Encodable, to file: URL) throws -> Int {
    var data = try JSONEncoder().encode(value)
    data.append(UInt8(ascii: "\n"))
    let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    try FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).write(contentsOf: data)
    return data.count
  }

  /// Deletes every table file and journal in `store`, including ones no table in this process
  /// loaded, and the SD card alias file that builds before 2026-11-18 kept there.
  static func discardAll(in store: URL) {
    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: store, includingPropertiesForKeys: nil)
    } catch CocoaError.fileReadNoSuchFile {
      return
    } catch {
      log.error("listing item tables failed: \(error, privacy: .private)")
      return
    }
    let names = ["json", "journal"]
    for file in files
    where names.contains(file.pathExtension) || file.lastPathComponent == "storage-aliases.plist" {
      remove(file)
    }
  }

  static func remove(_ file: URL) {
    do {
      try FileManager.default.removeItem(at: file)
    } catch CocoaError.fileNoSuchFile {
      return
    } catch {
      log.error("deleting item table failed: \(error, privacy: .private)")
    }
  }
}

// MARK: Saving and loading

extension ItemTable {
  /// Appends what changed since the last save to the journal, or folds the journal into a new
  /// snapshot once it has grown past the snapshot (or there is no snapshot yet), so the files
  /// never hold much more than the table.
  func save() {
    guard dirty, !discarded else { return }
    dirty = false
    guard snapshotBytes > 0, journalBytes <= max(snapshotBytes, Self.journalFloor) else {
      compact()
      return
    }
    var batch = Stored(items: [:], deleted: [], rootListed: rootListed)
    for id in touched {
      if let record = records[id] {
        batch.items[id.rawValue] = record
      } else {
        batch.deleted?.append(id.rawValue)
      }
    }
    touched = []
    do {
      journalBytes += try Self.append(batch, to: journal)
    } catch {
      // The folder may have gone (an append does not make it): a snapshot does, and holds
      // everything, so later saves append again.
      log.error("appending to the item table failed: \(error, privacy: .private)")
      compact()
    }
  }

  /// Writes the whole table as the snapshot and empties the journal.
  private func compact() {
    guard !discarded else { return }
    touched = []
    let stored = Stored(
      items: Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) }),
      rootListed: rootListed)
    do {
      snapshotBytes = try Self.write(stored, to: file)
      Self.remove(journal)
      journalBytes = 0
    } catch {
      log.error("saving item table failed: \(error, privacy: .private)")
    }
  }
}

extension ItemTable {
  /// The journal is folded into the snapshot once it is larger than this and than the snapshot.
  static let journalFloor = 256 * 1024
  /// Up to this many forgotten identifiers are taken out of `order` one search each.
  static let searchedRemovals = 64

  /// A table as read from its files.
  struct Loaded {
    var records: [ItemID: Record] = [:]
    var ids: [RemotePath: ItemID] = [:]
    var rootListed = false
    var snapshotBytes = 0
    var journalBytes = 0
    /// The journal ended in a batch that could not be read.
    var torn = false
  }

  static func load(_ file: URL, journal: URL) -> Loaded {
    guard let snapshot = read(file) else { return Loaded() }
    let batches = read(journal) ?? Data()
    do {
      var stored =
        snapshot.isEmpty
        ? Stored(items: [:], rootListed: false)
        : try JSONDecoder().decode(Stored.self, from: snapshot)
      var torn = false
      for line in batches.split(separator: UInt8(ascii: "\n")) {
        guard let batch = try? JSONDecoder().decode(Stored.self, from: line) else {
          log.error("item table journal ends in a torn batch; dropping it")
          torn = true
          break
        }
        stored.items.merge(batch.items) { $1 }
        for raw in batch.deleted ?? [] { stored.items[raw] = nil }
        stored.rootListed = batch.rootListed
      }
      var records: [ItemID: Record] = [:]
      var ids: [RemotePath: ItemID] = [:]
      for (raw, record) in stored.items {
        guard let id = ItemID(rawValue: raw), id != .root, record.path != .root,
          ids[record.path] == nil
        else { throw CocoaError(.fileReadCorruptFile) }
        records[id] = record
        ids[record.path] = id
      }
      return Loaded(
        records: records, ids: ids, rootListed: stored.rootListed, snapshotBytes: snapshot.count,
        journalBytes: batches.count, torn: torn)
    } catch {
      log.error("item table is unreadable, starting empty: \(error, privacy: .private)")
      return Loaded()
    }
  }

  /// The file's contents; empty when there is no file, `nil` when it cannot be read.
  private static func read(_ file: URL) -> Data? {
    do {
      return try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return Data()
    } catch {
      log.error("reading item table failed: \(error, privacy: .private)")
      return nil
    }
  }
}
