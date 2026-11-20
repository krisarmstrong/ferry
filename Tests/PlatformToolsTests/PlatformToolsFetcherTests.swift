import CryptoKit
import Foundation
import Testing
import os

@testable import PlatformTools

final class PlatformToolsFetcherTests: Sendable {
  private let home: URL
  private let folder: PlatformToolsFolder
  private let downloads = OSAllocatedUnfairLock(initialState: 0)

  init() throws {
    home = FileManager.default.temporaryDirectory.appending(
      path: "ferry-platform-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    folder = PlatformToolsFolder(home: home.path)
  }

  deinit {
    try? FileManager.default.removeItem(at: home)
  }

  private static let license = AndroidSDKLicense(
    id: "android-sdk-license", version: "2019-01-16", sha256: String(repeating: "0", count: 64))
  private static let accepted = LicenseAcceptance(
    version: "2019-01-16", date: Date(timeIntervalSince1970: 0))

  /// Google's layout, with more tools than Ferry takes.
  private static func googleLike(adb: String = "the adb binary") -> Data {
    var zip = TestZip()
    zip.add("platform-tools/", "", mode: 0o040_755, deflate: false)
    zip.add("platform-tools/adb", adb, mode: 0o100_755)
    zip.add("platform-tools/fastboot", "fastboot", mode: 0o100_755)
    zip.add("platform-tools/lib64/", "", mode: 0o040_755, deflate: false)
    zip.add("platform-tools/lib64/libc++.dylib", "libc++", mode: 0o100_755)
    zip.add("platform-tools/NOTICE.txt", "the notices")
    return zip.data
  }

  private static func release(
    for data: Data, version: String = "37.0.3",
    url: String = "https://dl.google.com/android/repository/platform-tools_r37.0.3-darwin.zip"
  ) -> PlatformToolsRelease {
    PlatformToolsRelease(
      version: version, url: URL(string: url)!, size: data.count,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      license: license)
  }

  /// A fetcher whose download hands over `served` as a new temporary file, as URLSession does.
  private func fetcher(
    _ release: PlatformToolsRelease, serving served: Data,
    verify: @escaping @Sendable (URL) throws(PlatformToolsError) -> Void = { _ in }
  ) -> (PlatformToolsFetcher, URL) {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "ferry-download-\(UUID().uuidString)")
    let fetcher = PlatformToolsFetcher(
      release: release, folder: folder,
      download: { [downloads] _ throws(PlatformToolsError) in
        downloads.withLock { $0 += 1 }
        do {
          try served.write(to: file)
        } catch {
          throw .storage
        }
        return file
      }, verify: verify)
    return (fetcher, file)
  }

  /// Everything under the folder, relative to it.
  private func leftovers() -> [String] {
    let root = folder.root
    guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
    return (walk.allObjects as? [String] ?? []).sorted()
  }

  private func mode(_ url: URL) throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  @Test func installsOnlyAdbAndItsNotice() async throws {
    let data = Self.googleLike()
    let (fetcher, download) = fetcher(Self.release(for: data), serving: data)
    let adb = try await fetcher.fetch(accepted: Self.accepted)
    #expect(adb == folder.root.appending(path: "37.0.3/adb"))
    #expect(try Data(contentsOf: adb) == Data("the adb binary".utf8))
    #expect(leftovers() == ["37.0.3", "37.0.3/NOTICE.txt", "37.0.3/adb"])
    #expect(try mode(adb) == 0o755)
    #expect(try mode(adb.deletingLastPathComponent()) == 0o700)
    #expect(!FileManager.default.fileExists(atPath: download.path))
  }

  @Test func noDownloadWithoutAcceptance() async {
    let data = Self.googleLike()
    let (fetcher, _) = fetcher(Self.release(for: data), serving: data)
    await #expect(throws: PlatformToolsError.licenseNotAccepted) {
      try await fetcher.fetch(accepted: nil)
    }
    await #expect(throws: PlatformToolsError.licenseNotAccepted) {
      try await fetcher.fetch(accepted: LicenseAcceptance(version: "2012-11-13", date: .now))
    }
    #expect(downloads.withLock { $0 } == 0)
    #expect(leftovers() == [])
  }

  @Test func onlyHTTPS() async {
    let data = Self.googleLike()
    let (fetcher, _) = fetcher(
      Self.release(for: data, url: "http://dl.google.com/platform-tools.zip"), serving: data)
    await #expect(throws: PlatformToolsError.insecureAddress) {
      try await fetcher.fetch(accepted: Self.accepted)
    }
    #expect(downloads.withLock { $0 } == 0)
  }

  @Test func aDifferentFileIsRejectedAndDeleted() async {
    let data = Self.googleLike()
    let other = Self.googleLike(adb: "the adb binarY")
    #expect(data.count == other.count)
    let (fetcher, download) = fetcher(Self.release(for: data), serving: other)
    await #expect(throws: PlatformToolsError.mismatch) {
      try await fetcher.fetch(accepted: Self.accepted)
    }
    #expect(!FileManager.default.fileExists(atPath: download.path))
    #expect(leftovers() == [])
  }

  @Test func aTruncatedDownloadIsRejectedAndDeleted() async {
    let data = Self.googleLike()
    let (fetcher, download) = fetcher(Self.release(for: data), serving: data.prefix(100))
    await #expect(throws: PlatformToolsError.mismatch) {
      try await fetcher.fetch(accepted: Self.accepted)
    }
    #expect(!FileManager.default.fileExists(atPath: download.path))
    #expect(leftovers() == [])
  }

  /// The checksum is checked first, so this needs a release pinned to the bad archive itself.
  @Test func aZipSlipArchiveIsRejected() async {
    var zip = TestZip()
    zip.add("platform-tools/adb", "adb", mode: 0o100_755)
    zip.add("platform-tools/../../../.zshrc", "evil")
    let data = zip.data
    let (fetcher, _) = fetcher(Self.release(for: data), serving: data)
    await #expect(throws: PlatformToolsError.badArchive) {
      try await fetcher.fetch(accepted: Self.accepted)
    }
    #expect(leftovers() == [])
    #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".zshrc").path))
  }

  @Test func aSymbolicLinkAdbIsRejected() async {
    var zip = TestZip()
    zip.add("platform-tools/adb", "/bin/sh", mode: 0o120_777)
    let data = zip.data
    let (fetcher, _) = fetcher(Self.release(for: data), serving: data)
    await #expect(throws: PlatformToolsError.badArchive) {
      try await fetcher.fetch(accepted: Self.accepted)
    }
    #expect(leftovers() == [])
  }

  @Test func anArchiveWithoutAdbIsRejected() async {
    var zip = TestZip()
    zip.add("platform-tools/fastboot", "fastboot", mode: 0o100_755)
    let data = zip.data
    let (fetcher, _) = fetcher(Self.release(for: data), serving: data)
    await #expect(throws: PlatformToolsError.badArchive) {
      try await fetcher.fetch(accepted: Self.accepted)
    }
    #expect(leftovers() == [])
  }

  /// The signature is checked on the extracted copy, before it reaches its folder.
  @Test func anAdbNotSignedByGoogleIsRejected() async {
    let data = Self.googleLike()
    let checked = OSAllocatedUnfairLock<[String]>(initialState: [])
    let refuse: PlatformToolsFetcher.Verify = { file throws(PlatformToolsError) in
      checked.withLock { $0.append(file.lastPathComponent) }
      throw .notSigned
    }
    let (fetcher, _) = fetcher(Self.release(for: data), serving: data, verify: refuse)
    await #expect(throws: PlatformToolsError.notSigned) {
      try await fetcher.fetch(accepted: Self.accepted)
    }
    #expect(checked.withLock { $0 } == ["adb"])
    #expect(leftovers() == [])
  }

  @Test func aFailedDownloadLeavesNothing() async {
    let fetcher = PlatformToolsFetcher(
      release: Self.release(for: Data()), folder: folder,
      download: { _ throws(PlatformToolsError) in throw .offline }, verify: { _ in })
    await #expect(throws: PlatformToolsError.offline) {
      try await fetcher.fetch(accepted: Self.accepted)
    }
    #expect(leftovers() == [])
  }

  /// A staging folder a crash left behind is cleared by the next fetch.
  @Test func anInterruptedFetchIsClearedNextTime() async throws {
    let stale = folder.root.appending(path: ".staging-old", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try Data("half".utf8).write(to: stale.appending(path: "adb"))
    let data = Self.googleLike()
    let (fetcher, _) = fetcher(Self.release(for: data), serving: data)
    _ = try await fetcher.fetch(accepted: Self.accepted)
    #expect(leftovers() == ["37.0.3", "37.0.3/NOTICE.txt", "37.0.3/adb"])
  }

  /// A new pinned version replaces the old one once it is in place, and not before.
  @Test func replacesAnOlderVersionOnlyOnSuccess() async throws {
    let old = Self.googleLike(adb: "old adb")
    _ = try await fetcher(Self.release(for: old, version: "36.0.0"), serving: old).0
      .fetch(accepted: Self.accepted)
    let new = Self.googleLike(adb: "new adb")
    await #expect(throws: PlatformToolsError.mismatch) {
      try await fetcher(Self.release(for: new, version: "37.0.3"), serving: old).0
        .fetch(accepted: Self.accepted)
    }
    #expect(leftovers() == ["36.0.0", "36.0.0/NOTICE.txt", "36.0.0/adb"])
    _ = try await fetcher(Self.release(for: new, version: "37.0.3"), serving: new).0
      .fetch(accepted: Self.accepted)
    #expect(leftovers() == ["37.0.3", "37.0.3/NOTICE.txt", "37.0.3/adb"])
  }
}

struct HTTPSDownloadTests {
  /// No connection is what the menu words as needing the internet once.
  @Test(arguments: [
    (URLError.Code.notConnectedToInternet, PlatformToolsError.offline), (.timedOut, .offline),
    (.cannotFindHost, .offline), (.networkConnectionLost, .offline), (.cancelled, .cancelled),
    (.serverCertificateUntrusted, .insecureAddress),
    (.appTransportSecurityRequiresSecureConnection, .insecureAddress),
    (.badServerResponse, .downloadFailed),
  ])
  func classifiesFailures(code: URLError.Code, expected: PlatformToolsError) {
    #expect(HTTPSDownload.failure(URLError(code)) == expected)
  }
}
