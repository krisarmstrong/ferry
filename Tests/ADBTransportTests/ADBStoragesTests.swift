import DeviceKit
import Testing

@testable import ADBTransport

struct ADBStoragesTests {
  /// `df -k /storage/emulated/0` on the LinkRunner (Android 8.1, toybox 0.7.4).
  static let linkRunner = """
    Filesystem     1K-blocks   Used Available Use% Mounted on
    /data/media     23260324 272504  22733788   2% /storage/emulated

    """

  @Test func dfGivesCapacityAndFreeInBytes() {
    #expect(
      ADBStorages.space(fromDF: Self.linkRunner)
        == ADBStorages.Space(capacity: 23_260_324 * 1024, free: 22_733_788 * 1024))
  }

  /// The figures are found by shape (four counts and a percentage), not by column position, so
  /// a filesystem name with spaces or one wrapped onto its own line still reads.
  @Test func dfIsReadByItsNumbersNotItsColumns() {
    let spaced =
      "Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/my disk 100 40 60 40% /mnt/x\n"
    #expect(ADBStorages.space(fromDF: spaced)?.capacity == 102_400)
    let wrapped =
      "Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/block/very/long\n 100 40 60 40% /mnt/x\n"
    #expect(ADBStorages.space(fromDF: wrapped)?.free == 61_440)
  }

  @Test(arguments: [
    "", "Filesystem 1K-blocks Used Available Use% Mounted on\n", "df: '/x': No such file",
  ])
  func dfWithoutFiguresIsNil(_ output: String) {
    #expect(ADBStorages.space(fromDF: output) == nil)
  }

  @Test(
    arguments: [
      ("1234-ABCD", true), ("0a1b-2c3d", true), ("8f3c3a5e-7b0d-4e8b-9a6e-0c1d2e3f4a5b", true),
      ("emulated", false), ("self", false), ("sdcard1", false), ("1234-ABC", false), ("", false),
    ])
  func volumeFoldersAreNamedByTheirIDs(_ name: String, _ isVolume: Bool) {
    #expect(StorageKey.isVolumeID(name) == isVolume)
  }

  @Test func storageKeysAreMethodNeutral() {
    #expect(StorageKey.internal == "internal")
    #expect(ADBStorages.root(forKey: "internal") == "/storage/emulated/0")
    #expect(ADBStorages.root(forKey: "volume:1234-ABCD") == "/storage/1234-ABCD")
    #expect(ADBStorages.root(forKey: "volume:../../data") == nil)
    #expect(ADBStorages.root(forKey: "Internal|vol0") == nil)
  }
}
