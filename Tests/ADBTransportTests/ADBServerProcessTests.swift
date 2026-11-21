import Darwin
import Foundation
import Testing

@testable import ADBTransport

/// Open in Terminal runs the adb that serves the server when Ferry can tell which one it is: the
/// executable of the process listening on the server's port.
struct ADBServerProcessTests {
  /// The fake server listens in this test process, so this process is the listener found.
  @Test func theListenerIsTheProcessOnThePort() async throws {
    let server = try await FakeADBServer.start { _ in }
    defer { server.stop() }
    let found = ADBServerProcess.executable(listeningOn: server.port)
    #expect(found != nil)
    #expect(found == ADBServerProcess.path(of: getpid()))
  }

  @Test func aPortNobodyListensOnHasNoListener() throws {
    let closed = try ClosedPort()
    #expect(ADBServerProcess.executable(listeningOn: closed.port) == nil)
  }
}

/// Which adb a shell in Terminal runs.
struct ShellADBTests {
  static func tools(serverExecutable: URL?, locator: ADBLocator = ADBHostTests.noAdb)
    -> ADBDeviceTools
  {
    ADBDeviceTools(
      host: ADBHost(port: 5037, locator: locator), answerLimit: .seconds(1),
      captureLimit: ADBDeviceTools.defaultCaptureLimit, captureWait: .seconds(1),
      serverExecutable: { serverExecutable })
  }

  static func executable(named name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ferry-server-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: name)
    try Data("#!/bin/sh\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
  }

  static let located = ADBLocator(
    environment: [:], home: "/Users/nobody",
    isExecutable: { $0 == "/opt/homebrew/bin/adb" }, fetched: { nil })

  /// Another tool's adb started the server: its own adb runs the shell, so no client of another
  /// version can restart that server.
  @Test func theServersAdbRunsTheShell() throws {
    let adb = try Self.executable(named: "adb")
    defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
    let shell = Self.tools(serverExecutable: adb, locator: Self.located).shellADB()
    #expect(shell == ShellADB(url: adb, runsServer: true))
  }

  /// No listener read, or a listener that is not an adb (a proxy, an emulator's): the located
  /// adb runs the shell, marked as a fallback.
  @Test func otherwiseTheLocatedAdbIsAFallback() throws {
    let proxy = try Self.executable(named: "adb-proxy")
    defer { try? FileManager.default.removeItem(at: proxy.deletingLastPathComponent()) }
    let expected = ShellADB(url: URL(fileURLWithPath: "/opt/homebrew/bin/adb"), runsServer: false)
    #expect(Self.tools(serverExecutable: nil, locator: Self.located).shellADB() == expected)
    #expect(Self.tools(serverExecutable: proxy, locator: Self.located).shellADB() == expected)
    let gone = URL(fileURLWithPath: "/nonexistent/adb")
    #expect(Self.tools(serverExecutable: gone, locator: Self.located).shellADB() == expected)
  }

  @Test func noAdbAnywhereIsNoShell() {
    #expect(Self.tools(serverExecutable: nil).shellADB() == nil)
  }
}
