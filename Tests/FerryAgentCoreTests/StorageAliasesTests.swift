import DeviceKit
import Testing

@testable import FerryAgentCore

struct StorageAliasesTests {
  static let id = DeviceID(serial: "S1")

  func storage(_ key: String, _ capacity: UInt64) -> StorageInfo {
    StorageInfo(
      id: StorageID(device: Self.id, key: key), description: "", capacity: capacity, free: 0)
  }

  /// The device's language changed, so MTP names the matched card anew: the match follows it.
  @Test func aRenamedCardKeepsItsVolume() {
    var aliases = StorageAliases()
    _ = aliases.learn(
      Self.id, mtp: [storage("SD card|", 1 << 30)], adb: [storage("volume:1234-ABCD", 1 << 30)])
    let learnt = aliases.learn(
      Self.id, mtp: [storage("Carte SD|", 1 << 30)], adb: [storage("volume:1234-ABCD", 1 << 30)])
    #expect(learnt.changed && learnt.replaced == nil)
    #expect(aliases.identity(of: storage("Carte SD|", 1 << 30)).key == "volume:1234-ABCD")
    #expect(aliases.identity(of: storage("SD card|", 1 << 30)).key == "SD card|")
  }

  /// Sizes that differ, or more than one candidate, match nothing.
  @Test func onlyAnUnambiguousMatchIsMade() {
    var aliases = StorageAliases()
    #expect(
      !aliases.learn(
        Self.id, mtp: [storage("SD card|", 1 << 30)], adb: [storage("volume:1234-ABCD", 1 << 31)]
      ).changed)
    #expect(
      !aliases.learn(
        Self.id, mtp: [storage("SD card|", 1 << 30)],
        adb: [storage("volume:1234-ABCD", 1 << 30), storage("volume:5678-ABCD", 1 << 30)]
      ).changed)
    #expect(aliases == StorageAliases())
  }
}
