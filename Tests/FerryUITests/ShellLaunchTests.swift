import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// Open Shell: the script Terminal runs is built only from a checked target, each part
/// single-quoted for zsh, in a private folder, and removes itself.
@MainActor
struct ShellLaunchTests {
  let log = CallLog()
  let id = DeviceID(serial: "0123456789abcdef")

  private func target(
    _ adb: String = "/opt/homebrew/bin/adb", _ serial: String = "0123456789abcdef"
  ) throws -> ShellTarget {
    try #require(ShellTarget(adb: adb, serial: serial))
  }

  @Test func eachPartIsSingleQuoted() throws {
    let script = ShellLaunch.script(
      for: try target(), file: URL(filePath: "/var/folders/ab/ferry-shell-X/shell.command"))
    #expect(script.hasPrefix("#!/bin/zsh\n"))
    #expect(script.contains("'/opt/homebrew/bin/adb' -s '0123456789abcdef' shell\n"))
  }

  /// A route adb gave a connection id selects the unit by it; one without uses the serial.
  @Test func thePinnedConnectionIsSelectedByItsID() throws {
    let file = URL(filePath: "/tmp/ferry-shell-X/shell.command")
    let pinned = try #require(
      ShellTarget(adb: "/opt/homebrew/bin/adb", serial: "192.0.2.31:5555", transportID: "7"))
    let script = ShellLaunch.script(for: pinned, file: file)
    #expect(script.contains("'/opt/homebrew/bin/adb' -t '7' shell\n"))
    #expect(!script.contains(" -s "))
    let unpinned = try target("/opt/homebrew/bin/adb", "192.0.2.31:5555")
    #expect(
      ShellLaunch.script(for: unpinned, file: file)
        .contains("'/opt/homebrew/bin/adb' -s '192.0.2.31:5555' shell\n"))
  }

  /// A path with a quote in it cannot end its quoting, in the adb path or the script's own.
  @Test func aQuoteInAPathStaysInsideItsQuoting() throws {
    let script = ShellLaunch.script(
      for: try target("/Users/o'brien/Android/adb"),
      file: URL(filePath: "/var/folders/it's/ferry-shell-X/shell.command"))
    #expect(script.contains("'/Users/o'\\''brien/Android/adb' -s "))
    #expect(script.contains("rm -f -- '/var/folders/it'\\''s/ferry-shell-X/shell.command'"))
  }

  @Test func theScriptRemovesItselfAndItsFolderBeforeRunningAdb() throws {
    let script = ShellLaunch.script(
      for: try target(), file: URL(filePath: "/tmp/ferry-shell-X/shell.command"))
    let lines = script.split(separator: "\n").map(String.init)
    #expect(
      lines == [
        "#!/bin/zsh", "rm -f -- '/tmp/ferry-shell-X/shell.command'",
        "rmdir -- '/tmp/ferry-shell-X' 2>/dev/null",
        "'/opt/homebrew/bin/adb' -s '0123456789abcdef' shell",
      ])
  }

  @Test func theScriptIsAPrivateExecutableFileInAPrivateFolder() throws {
    let base = try TestScratch.folder("shell-launch")
    let file = try ShellLaunch.prepare(try target(), in: base)
    #expect(file.pathExtension == "command")
    #expect(file.deletingLastPathComponent().deletingLastPathComponent().path == base.path)
    #expect(file.deletingLastPathComponent().lastPathComponent.hasPrefix("ferry-shell-"))
    func mode(_ url: URL) throws -> Int {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    #expect(try mode(file) == 0o700)
    #expect(try mode(file.deletingLastPathComponent()) == 0o700)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text == ShellLaunch.script(for: try target(), file: file))
  }

  @Test func eachLaunchGetsItsOwnFolder() throws {
    let base = try TestScratch.folder("shell-launch-2")
    let first = try ShellLaunch.prepare(try target(), in: base)
    let second = try ShellLaunch.prepare(try target(), in: base)
    #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
  }

  /// A script Terminal never ran (it was not installed, say) is swept the next time, once it is
  /// old enough that it cannot be waiting to start; nothing else in the folder is touched.
  @Test func oldLeftoversAreSwept() throws {
    let base = try TestScratch.folder("shell-sweep")
    let old = try ShellLaunch.prepare(try target(), in: base)
    let recent = try ShellLaunch.prepare(try target(), in: base)
    let other = base.appending(path: "keep-me")
    try Data("x".utf8).write(to: other)
    let longAgo = Date(timeIntervalSinceNow: -2 * 3600)
    try FileManager.default.setAttributes(
      [.modificationDate: longAgo], ofItemAtPath: old.deletingLastPathComponent().path)
    ShellLaunch.sweep(in: base)
    #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
  }

  // MARK: Through the model

  private func model(
    _ client: FakeClient, _ services: FakeServices
  ) -> AppModel {
    AppModel(client: client, services: services)
  }

  @Test func openShellAsksTheAgentThenHandsTerminalAScript() async throws {
    let client = FakeClient(log: log)
    let services = FakeServices(log: log)
    client.shellReply.withLock {
      $0 = .shellTarget(ShellTarget(adb: "/opt/homebrew/bin/adb", serial: "192.0.2.31:5555")!)
    }
    let model = model(client, services)
    await model.openShell(on: id)
    #expect(log.all.contains("shellTarget \(id.serial)"))
    #expect(services.terminalScripts.count == 1)
    #expect(model.actionError == nil)
    let script = try #require(services.terminalScripts.first)
    let text = try String(contentsOf: script, encoding: .utf8)
    #expect(text.contains("'/opt/homebrew/bin/adb' -s '192.0.2.31:5555' shell"))
    try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
  }

  @Test func withoutAdbTheMenuSaysSo() async {
    let client = FakeClient(log: log)
    let services = FakeServices(log: log)
    let model = model(client, services)
    await model.openShell(on: id)
    #expect(model.actionError == DevicePresentation.message(for: .adbNotFound))
    #expect(services.terminalScripts.isEmpty)
  }

  @Test func aTerminalThatWillNotOpenLeavesNoScriptAndSaysSo() async throws {
    let client = FakeClient(log: log)
    let services = FakeServices(log: log)
    services.terminalOpens = false
    client.shellReply.withLock {
      $0 = .shellTarget(ShellTarget(adb: "/opt/homebrew/bin/adb", serial: "S")!)
    }
    let model = model(client, services)
    await model.openShell(on: id)
    #expect(model.actionError != nil)
    let script = try #require(services.terminalScripts.first)
    #expect(!FileManager.default.fileExists(atPath: script.path))
  }
}
