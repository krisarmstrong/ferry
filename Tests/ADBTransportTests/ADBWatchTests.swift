import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Watching folders with the device's `inotifyd`: one connection for every folder, each event
/// reported as a hint for the folder its line names, until inotifyd exits, the session closes or
/// the caller stops.
@Suite(.timeLimit(.minutes(1)))
struct ADBWatchTests {
  let storage = ADBFixture.storage

  private func hint(_ folder: String) -> FolderHint {
    // Every name here makes a valid path.
    FolderHint(storage: storage, folder: (try? ADBFixture.path("/" + folder)) ?? .root)
  }

  private func events(_ text: String) -> [Data] { [Data(text.utf8)] }

  @Test func theFoldersAreWatchedOnOneConnection() async throws {
    let device = FakeAndroid()
    device.setTools { $0.inotifyEnds = true }
    try await ADBFixture.withSession(device) { session in
      let stream = try #require(
        await session.watch([hint("Download"), FolderHint(storage: storage, folder: .root)]))
      for await _ in stream {}
    }
    #expect(
      device.commands == [
        ["inotifyd", "-", "/storage/emulated/0:nwdDM", "/storage/emulated/0/Download:nwdDM"]
      ])
  }

  /// Any event is a hint for the folder on its line, whatever the event; lines split across
  /// reads count once whole, and lines for no watched folder are dropped.
  @Test func eachEventNamesItsFolder() async throws {
    let device = FakeAndroid()
    device.setTools {
      $0.inotify = [
        Data("d\t/storage/emulated/0/Download\tx\nn\t/storage/emu".utf8),
        Data("lated/0\tnew.txt\nw\t/storage/emulated/0/Other\ty\ngarbage\n".utf8),
        Data("D\t/storage/emulated/0/Download\n".utf8),
      ]
      $0.inotifyEnds = true
    }
    let hints = try await ADBFixture.withSession(device) { session in
      let stream = try #require(
        await session.watch([hint("Download"), FolderHint(storage: storage, folder: .root)]))
      var hints: [FolderHint] = []
      for await hint in stream { hints.append(hint) }
      return hints
    }
    #expect(
      hints == [
        hint("Download"), FolderHint(storage: storage, folder: .root), hint("Download"),
      ])
  }

  /// toybox reads `path:mask` up to a colon, so a folder whose path has one is not watched (the
  /// periodic listing still covers it), nor one whose path would break a line.
  @Test func pathsInotifydCannotTakeAreLeftOut() async throws {
    let device = FakeAndroid()
    device.setTools { $0.inotifyEnds = true }
    try await ADBFixture.withSession(device) { session in
      #expect(await session.watch([hint("a:b"), hint("tab\there")]) == nil)
      let stream = try #require(await session.watch([hint("a:b"), hint("Music")]))
      for await _ in stream {}
    }
    #expect(device.commands == [["inotifyd", "-", "/storage/emulated/0/Music:nwdDM"]])
  }

  @Test func closingTheSessionEndsTheWatch() async throws {
    let device = FakeAndroid()
    try await ADBFixture.withSession(device) { session in
      let stream = try #require(await session.watch([hint("Download")]))
      let started = try await ADBFixture.eventually {
        device.state.withLock { $0.tools.watching } == 1
      }
      #expect(started)
      await session.close()
      for await _ in stream {}
      #expect(await session.watch([hint("Download")]) == nil)
    }
    #expect(try await ADBFixture.eventually { device.state.withLock { $0.tools.watching } == 0 })
  }

  @Test func stoppingTheWatchClosesItsConnection() async throws {
    let device = FakeAndroid()
    device.setTools { $0.inotify = [Data("d\t/storage/emulated/0/Download\tx\n".utf8)] }
    try await ADBFixture.withSession(device) { session in
      #expect(await firstHint(session, [hint("Download")]) == hint("Download"))
      let stopped = try await ADBFixture.eventually {
        device.state.withLock { $0.tools.watching } == 0
      }
      #expect(stopped)
    }
  }

  /// The first hint of a watch, which the caller then stops by dropping the stream.
  private func firstHint(_ session: ADBSession, _ folders: [FolderHint]) async -> FolderHint? {
    guard let stream = await session.watch(folders) else { return nil }
    for await hint in stream { return hint }
    return nil
  }
}
