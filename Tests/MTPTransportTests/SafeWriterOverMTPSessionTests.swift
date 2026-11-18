import DeviceKit
import Foundation
import Testing

@testable import MTPTransport

/// `SafeWriter` composed on the real session, so its write rules are checked against MTP's
/// object-ID operations rather than the fake's path tree.
struct SafeWriterOverMTPSessionTests {
  let storage = SessionFixture.storage

  func write(
    _ data: Data, to path: String, on device: StubMTPDevice, replacing: Bool,
    in storage: StorageID = SessionFixture.storage
  ) async throws -> RemoteItem {
    let file = try SessionFixture.localFile(data)
    defer { try? FileManager.default.removeItem(at: file) }
    return try await SafeWriter(session: MTPSession(device: device)).write(
      from: file, to: SessionFixture.path(path), in: storage, replacing: replacing,
      progress: SessionFixture.noProgress)
  }

  func contents(of name: String, on device: StubMTPDevice) async -> Data? {
    await device.objects.values.first { $0.name == name }?.data
  }

  @Test func uploadsToAPartialThenRenames() async throws {
    let device = SessionFixture.makeDevice()
    let item = try await write(Data("new".utf8), to: "/a.txt", on: device, replacing: false)

    #expect(item.path == (try SessionFixture.path("/a.txt")))
    let calls = await device.calls
    #expect(calls.count == 2)
    guard case .upload(let partial, SessionFixture.root) = calls.first else {
      Issue.record("expected an upload first, got \(calls)")
      return
    }
    #expect(SafeWriter.isPartial(partial))
    guard case .rename(_, "a.txt") = calls.last else {
      Issue.record("expected a rename last, got \(calls)")
      return
    }
    #expect(await device.children(of: SessionFixture.root) == ["a.txt"])
    #expect(await contents(of: "a.txt", on: device) == Data("new".utf8))
  }

  /// Upload, set the old file aside, rename the new one into place, then delete the old one.
  @Test func replacingDeletesTheOldFileOnlyOnceTheNewOneIsInPlace() async throws {
    let device = SessionFixture.makeDevice()
    let old = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("old".utf8))
    _ = try await write(Data("new".utf8), to: "/a.txt", on: device, replacing: true)

    let calls = await device.calls
    #expect(calls.count == 4)
    guard case .rename(old, let backup) = calls[1] else {
      Issue.record("expected the old file set aside second, got \(calls)")
      return
    }
    #expect(SafeWriter.isBackup(backup))
    guard case .rename(_, "a.txt") = calls[2] else {
      Issue.record("expected the new file renamed into place third, got \(calls)")
      return
    }
    #expect(calls[3] == .delete(old))
    #expect(await device.children(of: SessionFixture.root) == ["a.txt"])
    #expect(await contents(of: "a.txt", on: device) == Data("new".utf8))
  }

  @Test(arguments: [false, true])
  func folderTargetIsNeverReplaced(replacing: Bool) async throws {
    let device = SessionFixture.makeDevice()
    let folder = await device.addFolder("A", parent: SessionFixture.root)
    await device.addFile("b.txt", parent: folder, data: Data("keep".utf8))

    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/A"))) {
      _ = try await write(Data("new".utf8), to: "/A", on: device, replacing: replacing)
    }
    #expect(await device.calls.isEmpty)
    #expect(await device.children(of: folder) == ["b.txt"])
  }

  /// The session's rename compares names without case, so replacing one of two case-variants
  /// would delete it and then fail on the other, losing the old file and the new one.
  @Test func replacingOneOfTwoCaseVariantsIsRefusedUpFront() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFile("foo.txt", parent: SessionFixture.root, data: Data("lower".utf8))
    await device.addFile("FOO.txt", parent: SessionFixture.root, data: Data("upper".utf8))

    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/FOO.txt"))) {
      _ = try await write(Data("new".utf8), to: "/foo.txt", on: device, replacing: true)
    }
    #expect(await device.calls.isEmpty)
    #expect(await contents(of: "foo.txt", on: device) == Data("lower".utf8))
    #expect(await contents(of: "FOO.txt", on: device) == Data("upper".utf8))
  }

  @Test func unknownStorageIsRejectedBeforeUpload() async throws {
    let device = SessionFixture.makeDevice()
    let unknown = StorageID(device: SessionFixture.deviceID, key: "SD card|vol9")

    await #expect(throws: TransportError.storageNotFound(unknown.key)) {
      _ = try await write(
        Data("new".utf8), to: "/a.txt", on: device, replacing: false, in: unknown)
    }
    #expect(await device.calls.isEmpty)
  }
}
