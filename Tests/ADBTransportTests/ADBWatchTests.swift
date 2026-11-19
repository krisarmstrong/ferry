import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Watching folders with the device's `inotifyd`: one connection for every folder, each named as
/// the device spells it, each event reported as a hint for the folder its line names, until
/// inotifyd exits, the session closes or the caller stops; and the process is killed by its pid
/// whenever the watch ends.
@Suite(.timeLimit(.minutes(1)))
struct ADBWatchTests {
  let storage = ADBFixture.storage
  static let script = ADBSession.watchScript

  private func hint(_ folder: String) -> FolderHint {
    // Every name here makes a valid path.
    FolderHint(storage: storage, folder: (try? ADBFixture.path(folder)) ?? .root)
  }

  private var root: FolderHint { FolderHint(storage: storage, folder: .root) }

  /// A device with `folders` under internal storage.
  private func device(_ folders: [String] = ["/Download"]) -> FakeAndroid {
    let device = FakeAndroid()
    for folder in folders { device.addFolder(folder) }
    return device
  }

  /// The `<folder>:<mask>` arguments of each watch the device started.
  private func watchArguments(_ device: FakeAndroid) -> [[String]] {
    device.commands.filter { $0.first == "sh" && $0.dropFirst(2).first == Self.script }
      .map { Array($0.dropFirst(4)) }
  }

  @Test func theFoldersAreWatchedOnOneConnection() async throws {
    let device = device()
    device.setTools { $0.inotifyEnds = true }
    try await ADBFixture.withSession(device) { session in
      let stream = try #require(await session.watch([hint("/Download"), root]))
      for await _ in stream {}
    }
    #expect(
      watchArguments(device) == [
        ["/storage/emulated/0:nwdDM", "/storage/emulated/0/Download:nwdDM"]
      ])
  }

  /// Any event is a hint for the folder on its line, whatever the event; lines split across
  /// reads count once whole, and lines for no watched folder are dropped.
  @Test func eachEventNamesItsFolder() async throws {
    let device = device()
    device.setTools {
      $0.inotify = [
        Data("d\t/storage/emulated/0/Download\tx\nn\t/storage/emu".utf8),
        Data("lated/0\tnew.txt\nw\t/storage/emulated/0/Other\ty\ngarbage\n".utf8),
        Data("D\t/storage/emulated/0/Download\n".utf8),
      ]
      $0.inotifyEnds = true
    }
    let hints = try await ADBFixture.withSession(device) { session in
      let stream = try #require(await session.watch([hint("/Download"), root]))
      var hints: [FolderHint] = []
      for await hint in stream { hints.append(hint) }
      return hints
    }
    #expect(hints == [hint("/Download"), root, hint("/Download")])
  }

  /// toybox reads `path:mask` up to a colon, so a folder whose path has one is not watched (the
  /// periodic listing still covers it), nor one whose path would break a line.
  @Test func pathsInotifydCannotTakeAreLeftOut() async throws {
    let device = device(["/a:b", "/tab\there", "/Music"])
    device.setTools { $0.inotifyEnds = true }
    try await ADBFixture.withSession(device) { session in
      #expect(await session.watch([hint("/a:b"), hint("/tab\there")]) == nil)
      let stream = try #require(await session.watch([hint("/a:b"), hint("/Music")]))
      for await _ in stream {}
    }
    #expect(watchArguments(device) == [["/storage/emulated/0/Music:nwdDM"]])
  }

  /// A folder stored in NFD is watched under the device's own spelling, and its events are
  /// hints for the folder Ferry knows; a folder the device no longer has is left out rather
  /// than ending the watch for the others.
  @Test func foldersAreWatchedAsTheDeviceSpellsThem() async throws {
    let device = device()
    let nfd = "Cafe\u{301}"
    device.addRaw("/", name: Array(nfd.utf8), node: .folder(mtime: 1))
    device.setTools {
      $0.inotify = [Data("n\t/storage/emulated/0/\(nfd)\tx\n".utf8)]
      $0.inotifyEnds = true
    }
    let cafe = hint("/Caf\u{E9}")
    let hints = try await ADBFixture.withSession(device) { session in
      let stream = try #require(await session.watch([cafe, hint("/Gone"), hint("/Download")]))
      var hints: [FolderHint] = []
      for await hint in stream { hints.append(hint) }
      return hints
    }
    // By bytes: `String` equality would take the NFC spelling for the NFD one.
    #expect(
      watchArguments(device).map { $0.map { Array($0.utf8) } } == [
        [
          Array("/storage/emulated/0/\(nfd):nwdDM".utf8),
          Array("/storage/emulated/0/Download:nwdDM".utf8),
        ]
      ])
    #expect(hints == [cafe])
  }

  /// A new watch (the folders changed) never leaves the previous inotifyd running.
  @Test func aRewatchKillsThePreviousProcess() async throws {
    let device = device(["/Download", "/Music"])
    var events = device.watchEvents.makeAsyncIterator()
    try await ADBFixture.withSession(device) { session in
      var first = await session.watch([hint("/Download")])
      #expect(first != nil)
      guard case .started(let pid, _) = await events.next() else {
        Issue.record("no watch started")
        return
      }
      first = nil
      _ = first
      let second = await session.watch([hint("/Download"), hint("/Music")])
      #expect(second != nil)
      var seen: [WatchEvent] = []
      func startedAnother() -> Bool {
        seen.contains { if case .started = $0 { true } else { false } }
      }
      while !(seen.contains(.killed(pid)) && startedAnother()), let event = await events.next() {
        seen.append(event)
      }
      #expect(seen.contains(.killed(pid)))
      #expect(startedAnother())
    }
  }

  @Test func closingTheSessionKillsTheWatch() async throws {
    let device = device()
    var events = device.watchEvents.makeAsyncIterator()
    try await ADBFixture.withSession(device) { session in
      let stream = try #require(await session.watch([hint("/Download")]))
      guard case .started(let pid, _) = await events.next() else {
        Issue.record("no watch started")
        return
      }
      await session.close()
      for await _ in stream {}
      #expect(await session.watch([hint("/Download")]) == nil)
      var seen: [WatchEvent] = []
      while !seen.contains(.killed(pid)), let event = await events.next() { seen.append(event) }
      #expect(seen.contains(.killed(pid)))
    }
  }

  @Test func stoppingTheWatchKillsItsProcess() async throws {
    let device = device()
    device.setTools { $0.inotify = [Data("d\t/storage/emulated/0/Download\tx\n".utf8)] }
    var events = device.watchEvents.makeAsyncIterator()
    try await ADBFixture.withSession(device) { session in
      #expect(await firstHint(session, [hint("/Download")]) == hint("/Download"))
      guard case .started(let pid, _) = await events.next() else {
        Issue.record("no watch started")
        return
      }
      var seen: [WatchEvent] = []
      while !seen.contains(.killed(pid)), let event = await events.next() { seen.append(event) }
      #expect(seen.contains(.killed(pid)))
    }
  }

  /// The first hint of a watch, which the caller then stops by dropping the stream.
  private func firstHint(_ session: ADBSession, _ folders: [FolderHint]) async -> FolderHint? {
    guard let stream = await session.watch(folders) else { return nil }
    for await hint in stream { return hint }
    return nil
  }
}
