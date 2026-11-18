import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import MTPTransport

/// A download must never leave a short file at the destination, nor disturb a file already
/// there unless it completes.
struct MTPSessionDownloadTests {
  let directory = TestScratch.root.appendingPathComponent(
    UUID().uuidString)
  var target: URL { directory.appendingPathComponent("a.txt") }

  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }

  func session(_ configure: (StubMTPDevice) async -> Void = { _ in }) async -> MTPSession {
    let device = SessionFixture.makeDevice()
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("hello".utf8))
    await configure(device)
    return MTPSession(device: device, scratch: TestScratch.root)
  }

  func download(_ session: MTPSession, replacing: Bool = false) async throws {
    try await session.download(
      SessionFixture.path("/a.txt"), in: SessionFixture.storage, to: target,
      replacing: replacing, progress: SessionFixture.noProgress)
  }

  func directoryContents() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  @Test func completeDownloadCreatesTheFile() async throws {
    defer { cleanUp() }
    try await download(session())
    #expect(try Data(contentsOf: target) == Data("hello".utf8))
    #expect(try directoryContents() == ["a.txt"])
  }

  @Test func downloadReplacingOverwrites() async throws {
    defer { cleanUp() }
    try Data("old".utf8).write(to: target)
    try await download(session(), replacing: true)
    #expect(try Data(contentsOf: target) == Data("hello".utf8))
    #expect(try directoryContents() == ["a.txt"])
  }

  @Test func downloadWithoutReplaceRefusesAnExistingFile() async throws {
    defer { cleanUp() }
    try Data("old".utf8).write(to: target)
    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/a.txt"))) {
      try await download(session())
    }
    #expect(try Data(contentsOf: target) == Data("old".utf8))
    #expect(try directoryContents() == ["a.txt"])
  }

  /// The race a caller's own existence check cannot close: the file appears after the check
  /// but before the download lands.
  @Test func downloadWithoutReplaceRefusesFileCreatedMidDownload() async throws {
    defer { cleanUp() }
    let session = await session { [target] in
      await $0.createDuringDownload(at: target, data: Data("theirs".utf8))
    }
    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/a.txt"))) {
      try await download(session)
    }
    #expect(try Data(contentsOf: target) == Data("theirs".utf8))
    #expect(try directoryContents() == ["a.txt"])
  }

  @Test(arguments: [false, true])
  func shortDownloadThrowsAndLeavesTheDestinationAlone(existing: Bool) async throws {
    defer { cleanUp() }
    if existing { try Data("old".utf8).write(to: target) }
    let session = await session { await $0.limitDownloads(to: 2) }
    await #expect(throws: TransportError.downloadSizeMismatch(listed: 5, received: 2)) {
      try await download(session, replacing: true)
    }
    #expect(try directoryContents() == (existing ? ["a.txt"] : []))
    if existing { #expect(try Data(contentsOf: target) == Data("old".utf8)) }
  }

  @Test(arguments: [false, true])
  func failedDownloadThrowsAndLeavesTheDestinationAlone(existing: Bool) async throws {
    defer { cleanUp() }
    if existing { try Data("old".utf8).write(to: target) }
    let session = await session { await $0.failNextDownload(with: .deviceDisconnected) }
    await #expect(throws: TransportError.deviceDisconnected) {
      try await download(session, replacing: true)
    }
    #expect(try directoryContents() == (existing ? ["a.txt"] : []))
    if existing { #expect(try Data(contentsOf: target) == Data("old".utf8)) }
  }
}
