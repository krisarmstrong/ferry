import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import ADBTransport
@testable import FerryAgentCore

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

  /// Guard: passes without the check too. A device without file-based encryption is served
  /// whatever its names look like.
  @Test func aDeviceWithoutFileBasedEncryptionIsNeverLocked() async throws {
    let device = Self.lockedDevice()
    device.state.withLock { $0.properties[ADBStorages.cryptoTypeProperty] = "block" }
    let storages = try await ADBFixture.withSession(device) { session in
      try await session.storages()
    }
    #expect(storages.map(\.id.key) == ["internal"])
  }

  /// A device with file-based encryption that does not say whether it is unlocked (the property
  /// empty, or `getprop` failing) is judged by its names: a folder shared storage has once in
  /// use shows it unlocked.
  @Test(arguments: [false, true])
  func aDeviceThatDoesNotSayIsServedWhenItsNamesAreReadable(getpropFails: Bool) async throws {
    let device = FakeAndroid()
    device.state.withLock { state in
      state.properties[ADBStorages.cryptoTypeProperty] = "file"
      state.nodes[FakeAndroid.bytes(FakeAndroid.internalRoot + "/Download")] = .folder(mtime: 1)
    }
    if getpropFails {
      // ro.crypto.type reads; the next getprop, sys.user.0.ce_available, fails.
      device.beforeNextShell("getprop") { android in
        android.beforeNextShell("getprop") { android in
          android.state.withLock { state in
            state.shellFailures.append(
              .init(program: "getprop", status: 1, stderr: "getprop: denied"))
          }
        }
      }
    }
    let storages = try await ADBFixture.withSession(device) { session in
      try await session.storages()
    }
    #expect(storages.map(\.id.key) == ["internal"])
  }

  /// The same device whose names look encrypted is locked.
  @Test func aDeviceThatDoesNotSayIsLockedWhenItsNamesLookEncrypted() async throws {
    try await ADBFixture.withSession(Self.lockedDevice()) { session in
      await #expect(throws: TransportError.deviceLocked) { _ = try await session.storages() }
    }
  }

  @Test func encryptedNamesAreToldFromPlainOnes() {
    #expect(ADBStorages.lookEncrypted(Self.ciphertext))
    #expect(ADBStorages.lookEncrypted(["xVjTfCPG9ycic,s5wEUphC", "io+bwYsdCgLebmszlHH44C"]))
    #expect(!ADBStorages.lookEncrypted([]))
    #expect(!ADBStorages.lookEncrypted(["Music", "U04Ll9plfc2KqbH3Q469BB"]))
    #expect(!ADBStorages.lookEncrypted(["a name with spaces in it, long"]))
    #expect(!ADBStorages.lookEncrypted(["ShortBase64Name+,"]))
  }

  /// The original failure from end to end: the device restarts and comes back before its first
  /// unlock, listing ciphertext names. The hub reads the new session and the reconnect relists
  /// the root only if it is ready; the domain's table keeps every identifier.
  @Test func aReconnectBeforeTheFirstUnlockKeepsTheTablesIdentifiers() async throws {
    let device = FakeAndroid()
    device.state.withLock { state in
      state.properties[ADBStorages.cryptoTypeProperty] = "file"
      state.properties[ADBStorages.credentialStorageProperty] = "true"
      state.nodes[FakeAndroid.bytes(FakeAndroid.internalRoot + "/Download")] = .folder(mtime: 1)
      state.nodes[FakeAndroid.bytes(FakeAndroid.internalRoot + "/Download/ferry-e2e")] =
        .folder(mtime: 1)
    }
    let store = TestScratch.root.appending(
      path: "ferry-items-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: store) }
    let table = ItemTable(domain: "locked-reconnect", store: store)
    let download = try RemotePath("/Download")
    let folder = try RemotePath("/Download/ferry-e2e")
    try await ADBFixture.withSession(device) { session in
      _ = try await session.storages()
      _ = await table.listed(.root, children: try await session.list(.root, in: ADBFixture.storage))
      _ = await table.listed(
        download, children: try await session.list(download, in: ADBFixture.storage))
    }
    let before = [await table.id(for: download), await table.id(for: folder)]

    device.state.withLock { state in
      state.properties[ADBStorages.credentialStorageProperty] = nil
      for path in ["/Download/ferry-e2e", "/Download"] {
        state.nodes[FakeAndroid.bytes(FakeAndroid.internalRoot + path)] = nil
      }
      for name in Self.ciphertext {
        state.nodes[FakeAndroid.bytes(FakeAndroid.internalRoot + "/" + name)] = .folder(mtime: 1)
      }
    }
    try await ADBFixture.withSession(device) { session in
      if case .state(.ready) = await DeviceHub.read(session) {
        _ = await table.listed(
          .root, children: try await session.list(.root, in: ADBFixture.storage))
      }
    }

    let known = (await table.knows(download), await table.knows(folder))
    #expect(known == (true, true))
    #expect([await table.id(for: download), await table.id(for: folder)] == before)
  }
}
