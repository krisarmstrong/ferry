import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Operations take turns, and a device lost mid-upload ends the session cleanly.
struct ADBSessionGateTests {
  let storage = ADBFixture.storage

  /// The gate keeps one upload's existence check and send together: without it both would find
  /// the name free, and adbd's SEND would replace the first file with the second.
  @Test func twoUploadsToOneNameLeaveTheFirstAndRefuseTheSecond() async throws {
    let device = FakeAndroid()
    let first = try ADBFixture.localFile(Data(repeating: 1, count: 200_000))
    let second = try ADBFixture.localFile(Data(repeating: 2, count: 200_000))
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let target = try RemotePath("/a.bin")
    let results = try await ADBFixture.withSession(device) { session in
      async let one = Result(catching: { () async throws(TransportError) in
        try await session.upload(
          from: first, to: target, in: storage, progress: ADBFixture.noProgress)
      })
      async let two = Result(catching: { () async throws(TransportError) in
        try await session.upload(
          from: second, to: target, in: storage, progress: ADBFixture.noProgress)
      })
      return await [one, two]
    }
    let succeeded = results.indices.filter { (try? results[$0].get()) != nil }
    #expect(succeeded.count == 1)
    for index in results.indices where !succeeded.contains(index) {
      #expect(throws: TransportError.alreadyExists(target)) { try results[index].get() }
    }
    let winner = succeeded.first ?? 0
    #expect(device.contents("/a.bin") == Data(repeating: UInt8(winner + 1), count: 200_000))
  }

  @Test func aDeviceUnpluggedMidUploadIsDisconnectedAndKeepsNoFile() async throws {
    let device = FakeAndroid()
    device.dropDuring("SEND", afterBytes: 65_536)
    let file = try ADBFixture.localFile(Data(count: 200_000))
    defer { try? FileManager.default.removeItem(at: file) }
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.deviceDisconnected) {
        _ = try await session.upload(
          from: file, to: RemotePath("/a.bin"), in: storage, progress: ADBFixture.noProgress)
      }
      #expect(await session.capabilities().isEmpty)
    }
    #expect(device.tree.isEmpty)
  }
}

extension Result where Failure == TransportError {
  init(catching body: () async throws(TransportError) -> Success) async {
    do {
      self = .success(try await body())
    } catch {
      self = .failure(error)
    }
  }
}
