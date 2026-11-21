import DeviceKit
import FerryIPC
import Foundation
import PlatformTools

@testable import FerryUI

@MainActor
final class FakeServices: SystemServicing {
  let log: CallLog
  var loginItem = LoginItemStatus.enabled
  var failLoginItem = false
  /// Set: a login item change waits until `releaseLoginItemChange()`, and each one held is
  /// announced on `loginItemChangesHeld`.
  var holdsLoginItemChange = false
  private var heldLoginItemChange: CheckedContinuation<Void, Never>?
  let (loginItemChangesHeld, loginItemChangeHeld) = AsyncStream<Void>.makeStream()
  var helper = HelperStatus.allowed
  /// Whether the app's executable was replaced since launch.
  var replaced = false

  init(log: CallLog) {
    self.log = log
  }

  func registerAgent() async {
    log.record("registerAgent")
  }

  /// The agent in the bundle, and the one last started; alike unless a test sets them.
  var agentOnDisk: String? = "agent-1"
  var startedAgent: String? = "agent-1"

  func agentBuild() -> String? { agentOnDisk }
  func startedAgentBuild() -> String? { startedAgent }

  func recordStartedAgent(_ build: String) {
    log.record("recordStartedAgent \(build)")
    startedAgent = build
  }

  /// Whether a restart registers the new agent.
  var restartSucceeds = true

  func restartAgent() async -> Bool {
    log.record("restartAgent")
    return restartSucceeds
  }

  func helperStatus() async -> HelperStatus {
    helper
  }

  /// Set: the next read answers what it found once `releaseLoginItemRead()` is called, and is
  /// announced on `loginItemReadsHeld`.
  var holdsNextLoginItemRead = false
  private var heldLoginItemRead: CheckedContinuation<Void, Never>?
  let (loginItemReadsHeld, loginItemReadHeld) = AsyncStream<Void>.makeStream()

  func loginItemStatus() async -> LoginItemStatus {
    log.record("readLoginItem")
    let found = loginItem
    if holdsNextLoginItemRead {
      holdsNextLoginItemRead = false
      await withCheckedContinuation { continuation in
        heldLoginItemRead = continuation
        loginItemReadHeld.yield()
      }
    }
    return found
  }

  func releaseLoginItemRead() {
    heldLoginItemRead?.resume()
    heldLoginItemRead = nil
  }

  func setOpensAtLogin(_ enabled: Bool) async throws {
    log.record("opensAtLogin \(enabled)")
    if holdsLoginItemChange {
      await withCheckedContinuation { continuation in
        heldLoginItemChange = continuation
        loginItemChangeHeld.yield()
      }
    }
    if failLoginItem { throw CocoaError(.featureUnsupported) }
    loginItem = enabled ? .enabled : .disabled
  }

  func releaseLoginItemChange() {
    heldLoginItemChange?.resume()
    heldLoginItemChange = nil
  }

  func unregisterAgent() async throws {
    log.record("unregisterAgent")
  }

  func removeAgentData() throws {
    log.record("removeAgentData")
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

  func announce(_ text: String) {
    log.record("announce \(text)")
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

  /// The license acceptance in Ferry's defaults, and the version Ferry has fetched.
  var acceptance: LicenseAcceptance?
  var fetchedVersion: String?
  /// How the next fetches end, in order; once it is empty they succeed.
  var fetchOutcomes: [PlatformToolsError] = []
  /// Set: a fetch waits until it is cancelled or `releaseFetch()` lets it go on, and each one
  /// held is announced on `fetchesHeld`.
  var holdsFetch = false
  private var heldFetch: CheckedContinuation<Void, Never>?
  let (fetchesHeld, fetchHeld) = AsyncStream<Void>.makeStream()

  func platformToolsAcceptance() -> LicenseAcceptance? { acceptance }

  func recordPlatformToolsAcceptance(_ acceptance: LicenseAcceptance) {
    log.record("acceptLicense \(acceptance.version)")
    self.acceptance = acceptance
  }

  func fetchedPlatformToolsVersion() -> String? { fetchedVersion }

  /// Lets the held fetch go on to its outcome.
  func releaseFetch() {
    holdsFetch = false
    heldFetch?.resume()
    heldFetch = nil
  }

  func fetchPlatformTools(accepted: LicenseAcceptance?) async throws(PlatformToolsError) {
    log.record("fetchPlatformTools \(accepted?.version ?? "none")")
    if holdsFetch {
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          guard !Task.isCancelled else { return continuation.resume() }
          heldFetch = continuation
          fetchHeld.yield()
        }
      } onCancel: {
        Task { @MainActor in
          self.heldFetch?.resume()
          self.heldFetch = nil
        }
      }
      if Task.isCancelled { throw .cancelled }
    }
    if !fetchOutcomes.isEmpty { throw fetchOutcomes.removeFirst() }
    fetchedVersion = PlatformToolsRelease.pinned.version
  }
}
