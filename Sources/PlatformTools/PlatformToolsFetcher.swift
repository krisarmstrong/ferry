import CryptoKit
import Foundation
import os

/// Fetches the pinned platform tools into `PlatformToolsFolder`, once the user has accepted the
/// license: downloads the archive over HTTPS, checks its size and SHA-256 before reading it,
/// takes only `platform-tools/adb` and `platform-tools/NOTICE.txt` into a staging folder, checks
/// that the `adb` there is signed by Google, and only then moves the folder into place and
/// removes the versions fetched before. Whatever fails, nothing is left behind but what was
/// there before.
public struct PlatformToolsFetcher: Sendable {
  /// Downloads `url` into a new file in `folder`, giving up past `limit` bytes.
  public typealias Download =
    @Sendable (_ url: URL, _ limit: Int, _ folder: URL) async throws(PlatformToolsError) -> URL
  public typealias Verify = @Sendable (URL) throws(PlatformToolsError) -> Void

  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "PlatformTools")

  let release: PlatformToolsRelease
  let folder: PlatformToolsFolder
  private let download: Download
  private let verify: Verify

  /// `download` returns a new file that the fetcher then owns and deletes; `verify` throws
  /// unless its file is signed by Google.
  public init(
    release: PlatformToolsRelease = .pinned, folder: PlatformToolsFolder = .standard,
    download: @escaping Download = HTTPSDownload.file(from:limit:into:),
    verify: @escaping Verify = CodeSignature.checkGoogle
  ) {
    self.release = release
    self.folder = folder
    self.download = download
    self.verify = verify
  }

  /// Returns the installed `adb`.
  public func fetch(accepted: LicenseAcceptance?) async throws(PlatformToolsError) -> URL {
    guard let accepted, accepted.covers(release.license) else { throw .licenseNotAccepted }
    guard release.url.scheme?.lowercased() == "https" else { throw .insecureAddress }
    let staging = try makeStaging()
    defer { try? FileManager.default.removeItem(at: staging) }
    let downloaded = try await download(release.url, release.size, staging)
    // Read, then gone at once: the staging folder becomes the version folder.
    let archive: Data
    do {
      defer { try? FileManager.default.removeItem(at: downloaded) }
      archive = try Data(contentsOf: downloaded)
    } catch {
      throw .storage
    }
    guard archive.count == release.size, Self.hex(SHA256.hash(data: archive)) == release.sha256
    else {
      Self.log.error("platform tools download is \(archive.count) bytes, not the pinned archive")
      throw .mismatch
    }
    let zip = try ZipArchive(archive)
    guard let adb = try zip.contents(of: "platform-tools/adb"),
      let notice = try zip.contents(of: "platform-tools/NOTICE.txt")
    else { throw .badArchive }
    try write(adb, to: staging.appending(path: "adb"), mode: 0o755)
    try write(notice, to: staging.appending(path: "NOTICE.txt"), mode: 0o644)
    try verify(staging.appending(path: "adb"))
    try install(staging)
    return folder.adb(version: release.version)
  }

  /// A new private folder beside the version folders, so moving it into place is one rename.
  /// Staging folders a crash left behind are removed first.
  private func makeStaging() throws(PlatformToolsError) -> URL {
    let files = FileManager.default
    do {
      try files.createDirectory(
        at: folder.root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      for name in try files.contentsOfDirectory(atPath: folder.root.path)
      where name.hasPrefix(Self.stagingPrefix) {
        try files.removeItem(at: folder.root.appending(path: name))
      }
      let staging = folder.root.appending(
        path: Self.stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
      try files.createDirectory(
        at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      return staging
    } catch {
      Self.log.error("platform tools folder: \(error, privacy: .public)")
      throw .storage
    }
  }

  private static let stagingPrefix = ".staging-"

  private func write(_ data: Data, to file: URL, mode: Int) throws(PlatformToolsError) {
    guard
      FileManager.default.createFile(
        atPath: file.path, contents: data, attributes: [.posixPermissions: mode])
    else { throw .storage }
  }

  /// Puts the staged version in place of any copy of it, then removes the other versions.
  private func install(_ staging: URL) throws(PlatformToolsError) {
    let files = FileManager.default
    let target = folder.root.appending(path: release.version, directoryHint: .isDirectory)
    do {
      if files.fileExists(atPath: target.path) {
        _ = try files.replaceItemAt(target, withItemAt: staging)
      } else {
        try files.moveItem(at: staging, to: target)
      }
    } catch {
      Self.log.error("platform tools install: \(error, privacy: .public)")
      throw .storage
    }
    for version in folder.versions() where version != release.version {
      try? files.removeItem(at: folder.root.appending(path: version))
    }
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
