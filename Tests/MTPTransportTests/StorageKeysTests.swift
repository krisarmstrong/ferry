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
}
