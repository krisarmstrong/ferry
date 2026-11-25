import DeviceKitTestSupport
import Foundation
import Testing

@testable import DeviceKit

/// What a write may and may not replace at its target name.
extension SafeWriterTests {
  @Test(arguments: [false, true])
  func folderAtTargetIsNeverReplaced(replacing: Bool) async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device, backups: .scratch())
    let folder = try RemotePath("/A")
    let inside = try RemotePath("/A/b.txt")
    try await device.seed(inside, in: storageID, contents: Data([9]))
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.alreadyExists(folder)) {
        _ = try await writer.write(from: file, to: folder, replacing: replacing)
      }
    }
    #expect(await device.allPaths(in: storageID) == [folder, inside])
    #expect(await device.contents(of: inside, in: storageID) == Data([9]))
  }

  /// Android storage compares names without case, and its rename may replace what is there.
  @Test func caseVariantIsTakenWhenNotReplacing() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device, backups: .scratch())
    let existing = try RemotePath("/foo.txt")
    try await device.seed(existing, in: storageID, contents: Data([9]))
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.alreadyExists(existing)) {
        _ = try await writer.write(from: file, to: RemotePath("/Foo.txt"), replacing: false)
      }
    }
    #expect(await device.allPaths(in: storageID) == [existing])
    #expect(await device.contents(of: existing, in: storageID) == Data([9]))
  }

  @Test func replacingACaseVariantReplacesThatItem() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device, backups: .scratch())
    let path = try RemotePath("/Foo.txt")
    try await device.seed(RemotePath("/foo.txt"), in: storageID, contents: Data([9]))
    try await withTempFile(Data([1, 2])) { file in
      _ = try await writer.write(from: file, to: path, replacing: true)
    }
    #expect(await device.allPaths(in: storageID) == [path])
    #expect(await device.contents(of: path, in: storageID) == Data([1, 2]))
  }

  /// With two names differing only in case, the rename would collide with whichever is left,
  /// so the write is refused before anything is uploaded or deleted.
  @Test(arguments: [false, true])
  func twoCaseVariantsAreRefusedUpFront(replacing: Bool) async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device, backups: .scratch())
    let exact = try RemotePath("/foo.txt")
    let variant = try RemotePath("/FOO.txt")
    try await device.seed(variant, in: storageID, contents: Data([8]))
    try await device.seed(exact, in: storageID, contents: Data([9]))
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.alreadyExists(variant)) {
        _ = try await writer.write(from: file, to: exact, replacing: replacing)
      }
    }
    #expect(await device.contents(of: exact, in: storageID) == Data([9]))
    #expect(await device.contents(of: variant, in: storageID) == Data([8]))
    #expect(await device.allPaths(in: storageID) == [variant, exact])
  }

  @Test func folderCaseVariantIsNeverReplaced() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device, backups: .scratch())
    let folder = try RemotePath("/A")
    try await device.seed(RemotePath("/A/b.txt"), in: storageID, contents: Data([9]))
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.alreadyExists(folder)) {
        _ = try await writer.write(from: file, to: RemotePath("/a"), replacing: true)
      }
    }
    let inside = try RemotePath("/A/b.txt")
    #expect(await device.contents(of: inside, in: storageID) == Data([9]))
  }
}
