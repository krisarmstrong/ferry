import CryptoKit
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

  /// Deletes `domain`'s table file, for a domain whose table is not loaded.
  static func discard(domain: String, in store: URL) {
    remove(file(for: domain, in: store))
  }

  /// Deletes every table file in `store`, including ones no table in this process loaded.
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
    for file in files where file.pathExtension == "json" {
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
