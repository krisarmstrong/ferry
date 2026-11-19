import DeviceKit
import FerryIPC
import Foundation

@testable import FerryUI

@MainActor
final class FakeServices: SystemServicing {
  let log: CallLog
  var loginItem = true
  var failLoginItem = false
  var helper = HelperStatus.allowed
  /// Whether the app's executable was replaced since launch.
  var replaced = false

  init(log: CallLog) {
    self.log = log
  }

  func registerAgent() async {
    log.record("registerAgent")
  }

  func helperStatus() async -> HelperStatus {
    helper
  }

  func opensAtLogin() async -> Bool {
    log.record("readLoginItem")
    return loginItem
  }

  func setOpensAtLogin(_ enabled: Bool) async throws {
    log.record("opensAtLogin \(enabled)")
    if failLoginItem { throw CocoaError(.featureUnsupported) }
    loginItem = enabled
  }

  func unregisterAgent() async throws {
    log.record("unregisterAgent")
  }

  func open(_ url: URL) {
    log.record("open \(url.absoluteString)")
  }

  func reveal(_ urls: [URL]) {
    log.record("reveal \(urls.map(\.path).joined(separator: ","))")
  }

  func quit() {
    log.record("quit")
  }

  func appWasReplaced() -> Bool { replaced }
  func relaunch() { log.record("relaunch") }

  func copy(_ text: String) {
    log.record("copy \(text)")
  }

  /// What the open panel returns: `nil` is Cancel.
  var pickedAPK: URL?
  /// Where captures go.
  var folders: [URL] = []

  func captureFolders() -> [URL] {
    log.record("captureFolders")
    return folders
  }

  /// What the folder panel returns: `nil` is Cancel.
  var chosenFolder: URL?

  func chooseFolder() async -> URL? {
    log.record("chooseFolder")
    return chosenFolder
  }

  func chooseAPK() async -> URL? {
    log.record("chooseAPK")
    return pickedAPK
  }

  /// What the open panel for Send File… returns: empty is Cancel.
  var pickedFiles: [URL] = []

  func chooseFilesToSend() async -> [URL] {
    log.record("chooseFilesToSend")
    return pickedFiles
  }

  /// What the save panel for a log returns: `nil` is Cancel.
  var logDestination: URL?
  /// The scripts handed to Terminal, and whether it opens them.
  var terminalScripts: [URL] = []
  var terminalOpens = true

  func chooseLogDestination(suggestedName: String) async -> URL? {
    log.record("chooseLogDestination \(suggestedName)")
    return logDestination
  }

  func openInTerminal(_ script: URL) async -> Bool {
    log.record("openInTerminal \(script.lastPathComponent)")
    terminalScripts.append(script)
    return terminalOpens
  }
}
