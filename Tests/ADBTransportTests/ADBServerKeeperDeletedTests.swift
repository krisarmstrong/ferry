import Foundation
import Testing

@testable import ADBTransport

/// A server whose fetched adb was deleted under it (Remove Ferry, or the user) still answers,
/// so the copy Ferry fetches next would never run unless that server is replaced.
struct ADBServerKeeperDeletedTests {
  typealias Keeper = ADBServerKeeperTests

  /// Ferry's fetched folder, where `adb` lives as `<version>/adb`.
  static let fetched = Keeper.adb.deletingLastPathComponent().deletingLastPathComponent()

  /// Remove Ferry, or anything else, deleted Ferry's adb while its server kept running: the
  /// server answers, so nothing starts the fetched copy that replaces it. It is replaced.
  @Test func aServerOfADeletedFerryADBIsReplaced() async {
    let fakes = Keeper.Fakes()
    fakes { state in
      state.answering = true
      state.listener = 33
      state.paths[33] = Keeper.adb.path
    }
    let keeper = Keeper.keeper(fakes, record: Keeper.recordFile(), exists: { _ in false })
    #expect(await keeper.replaceServerOfDeletedADB(fetched: Self.fetched))
    #expect(fakes { $0.kills } == 1)
  }

  /// Its program still there, or not Ferry's: left alone.
  @Test(arguments: [(Keeper.adb.path, true), ("/opt/homebrew/bin/adb", false)])
  func aServerWhoseADBIsThereOrNotFerrysIsLeftAlone(path: String, exists: Bool) async {
    let fakes = Keeper.Fakes()
    fakes { state in
      state.answering = true
      state.listener = 33
      state.paths[33] = path
    }
    let keeper = Keeper.keeper(fakes, record: Keeper.recordFile(), exists: { _ in exists })
    #expect(await keeper.replaceServerOfDeletedADB(fetched: Self.fetched) == false)
    #expect(fakes { $0.kills } == 0)
  }
}
