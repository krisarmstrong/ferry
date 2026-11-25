import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// A device with file-based encryption, restarted and not unlocked yet, still has
/// `/storage/emulated/0`, but its names are ciphertext. Served, that listing reads as every item
/// deleted and others made, so the session reports the device locked until it is unlocked.
struct ADBSessionLockedStorageTests {
  /// What the EtherScope listed for `/Download` and `/DCIM` before its first unlock.
  static let ciphertext = ["U04Ll9plfc2KqbH3Q469BB", "BBIK1bhsNe4U7rNJAPftyD"]

  static func lockedDevice() -> FakeAndroid {
    let device = FakeAndroid()
    device.state.withLock { state in
      state.properties[ADBStorages.cryptoTypeProperty] = "file"
      for name in ciphertext {
        state.nodes[FakeAndroid.bytes(FakeAndroid.internalRoot + "/" + name)] = .folder(mtime: 1)
      }
    }
    return device
  }

  @Test func encryptedStorageBeforeTheFirstUnlockIsLocked() async throws {
    let device = Self.lockedDevice()
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.deviceLocked) { _ = try await session.storages() }
      await #expect(throws: TransportError.deviceLocked) {
        _ = try await session.list(.root, in: ADBFixture.storage)
      }
    }
  }

  @Test func unlockingServesTheStorage() async throws {
    let device = Self.lockedDevice()
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.deviceLocked) { _ = try await session.storages() }
      device.state.withLock { state in
        state.properties[ADBStorages.credentialStorageProperty] = "true"
        for name in Self.ciphertext {
          state.nodes[FakeAndroid.bytes(FakeAndroid.internalRoot + "/" + name)] = nil
        }
        state.nodes[FakeAndroid.bytes(FakeAndroid.internalRoot + "/Download")] = .folder(mtime: 1)
      }
      let storages = try await session.storages()
      #expect(storages.map(\.id.key) == ["internal"])
      let listed = try await session.list(.root, in: ADBFixture.storage)
      let download = try RemotePath("/Download")
      #expect(listed.map(\.path) == [download])
    }
  }

  /// Unlocked stays unlocked until the device restarts, which ends the session: the properties
  /// are not read again.
  @Test func anUnlockedDeviceIsAskedOnce() async throws {
    let device = Self.lockedDevice()
    device.state.withLock { $0.properties[ADBStorages.credentialStorageProperty] = "true" }
    try await ADBFixture.withSession(device) { session in
      _ = try await session.storages()
      _ = try await session.storages()
    }
    let reads = device.state.withLock { $0.commands.filter { $0.first == "getprop" } }
    #expect(reads.count == 2)
  }

  @Test func aDeviceWithoutFileBasedEncryptionIsNeverLocked() async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.properties[ADBStorages.cryptoTypeProperty] = "block" }
    let storages = try await ADBFixture.withSession(device) { session in
      try await session.storages()
    }
    #expect(storages.map(\.id.key) == ["internal"])
  }
}
