import Testing

@testable import MTPTransport

struct StorageKeysTests {
  func storage(_ raw: UInt32, _ description: String?, _ volume: String?) -> RawStorage {
    RawStorage(raw: raw, description: description, volume: volume)
  }

  @Test func normalStorageKeepsDescriptionAndVolume() {
    let keys = storageKeys(for: [storage(0x0001_0001, "Internal", "vol0")])
    #expect(keys == [0x0001_0001: "Internal|vol0"])
  }

  @Test func emptyDescriptionAndVolumeGetRawID() {
    let keys = storageKeys(for: [storage(0x0001_0001, nil, nil), storage(0x0002_0001, "", "")])
    #expect(keys[0x0001_0001] == "||#00010001")
    #expect(keys[0x0002_0001] == "||#00020001")
  }

  @Test func libmtpPlaceholdersGetRawID() {
    let keys = storageKeys(for: [storage(0x0001_0001, "Unknown storage", "Unknown volume")])
    #expect(keys == [0x0001_0001: "Unknown storage|Unknown volume|#00010001"])
  }

  @Test func duplicateKeysGetRawIDOthersDoNot() {
    let first = storage(0x0001_0001, "SD card", "x")
    let second = storage(0x0002_0001, "SD card", "x")
    let third = storage(0x0003_0001, "SD card", "y")
    let keys = storageKeys(for: [first, second, third])
    #expect(keys[0x0001_0001] == "SD card|x|#00010001")
    #expect(keys[0x0002_0001] == "SD card|x|#00020001")
    #expect(keys[0x0003_0001] == "SD card|y")
  }

  @Test func keysDoNotDependOnInputOrder() {
    let first = storage(0x0001_0001, "Internal", nil)
    let second = storage(0x0002_0001, "Internal", nil)
    let third = storage(0x0003_0001, "SD card", "z")
    #expect(storageKeys(for: [first, second, third]) == storageKeys(for: [third, second, first]))
    #expect(storageKeys(for: [first, second, third]).count == 3)
  }

  // MARK: Method-neutral keys

  func android(
    _ raw: UInt32, _ description: String?, _ volume: String?, type: UInt16
  ) -> RawStorage {
    RawStorage(raw: raw, description: description, volume: volume, type: type)
  }

  static let fixedRAM: UInt16 = 0x0003
  static let removableRAM: UInt16 = 0x0004

  /// Android's primary shared storage is always storage 0x00010001, a fixed RAM storage, with an
  /// empty volume identifier and a description in the device's language.
  @Test(arguments: ["Internal shared storage", "Interner gemeinsamer Speicher", ""])
  func androidPrimaryStorageIsInternal(_ description: String) {
    let keys = storageKeys(for: [android(0x0001_0001, description, "", type: Self.fixedRAM)])
    #expect(keys == [0x0001_0001: "internal"])
  }

  @Test func aVolumeIdentifierThatIsAFilesystemIDNamesTheVolume() {
    let keys = storageKeys(for: [
      android(0x0001_0001, "Internal shared storage", nil, type: Self.fixedRAM),
      android(0x0002_0001, "SD card", "1234-ABCD", type: Self.removableRAM),
      android(0x0003_0001, "USB drive", "8f3c3a5e-7b0d-4e8b-9a6e-0c1d2e3f4a5b", type: 4),
    ])
    #expect(keys[0x0002_0001] == "volume:1234-ABCD")
    #expect(keys[0x0003_0001] == "volume:8f3c3a5e-7b0d-4e8b-9a6e-0c1d2e3f4a5b")
  }

  /// Android's MTP server sends an empty volume identifier, so its SD card cannot be matched to
  /// the `/storage/<UUID>` ADB serves: it keeps its MTP key, and only MTP serves it.
  @Test func unmatchedStoragesKeepTheirMTPKeys() {
    let keys = storageKeys(for: [
      android(0x0001_0001, "Internal shared storage", "", type: Self.fixedRAM),
      android(0x0002_0001, "SanDisk SD card", "", type: Self.removableRAM),
      android(0x0003_0001, "Phone", "", type: Self.fixedRAM),
      android(0x0004_0001, "Card", "sdcard1", type: Self.removableRAM),
    ])
    #expect(keys[0x0001_0001] == "internal")
    #expect(keys[0x0002_0001] == "SanDisk SD card|")
    #expect(keys[0x0003_0001] == "Phone|")
    #expect(keys[0x0004_0001] == "Card|sdcard1")
  }

  /// Storage 0x00010001 counts as the primary only when it is fixed: a camera's first storage
  /// is often its removable card.
  @Test func aRemovableFirstStorageIsNotInternal() {
    let keys = storageKeys(for: [android(0x0001_0001, "SD", "", type: Self.removableRAM)])
    #expect(keys == [0x0001_0001: "SD|"])
  }

  @Test func twoStoragesClaimingOneVolumeKeepTheirMTPKeys() {
    let keys = storageKeys(for: [
      android(0x0002_0001, "SD card", "1234-ABCD", type: Self.removableRAM),
      android(0x0003_0001, "SD card", "1234-ABCD", type: Self.removableRAM),
    ])
    #expect(keys[0x0002_0001] == "SD card|1234-ABCD|#00020001")
    #expect(keys[0x0003_0001] == "SD card|1234-ABCD|#00030001")
  }

  /// A storage only MTP serves is keyed by its description and volume.
  @Test func describedKeysAreTheDescriptionAndVolume() {
    let storages = [
      android(0x0001_0001, "Internal shared storage", "", type: Self.fixedRAM),
      android(0x0002_0001, "SD card", "1234-ABCD", type: Self.removableRAM),
      android(0x0003_0001, nil, nil, type: Self.removableRAM),
    ]
    #expect(
      describedStorageKeys(for: storages) == [
        0x0001_0001: "Internal shared storage|", 0x0002_0001: "SD card|1234-ABCD",
        0x0003_0001: "||#00030001",
      ])
  }
}
