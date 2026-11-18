import AppKit
import ServiceManagement
import os

/// The system calls `AppModel` makes outside the agent, behind a protocol so tests can check
/// their order with a fake.
@MainActor
public protocol SystemServicing {
  /// Registers the agent, which launchd then starts on demand. Registering again is harmless.
  func registerAgent() async
  /// Whether Ferry opens at login.
  func opensAtLogin() async -> Bool
  func setOpensAtLogin(_ enabled: Bool) async throws
  func unregisterAgent() async throws
  func open(_ url: URL)
  /// Shows the items in Finder.
  func reveal(_ urls: [URL])
  func quit()
}

/// `SMAppService`, `NSWorkspace` and `NSApplication`.
///
/// `SMAppService` checks code signatures and talks to launchd, which may block, and macOS flags
/// it when called on the main thread; every call to it runs on a detached utility task.
@MainActor
public final class SystemServices: SystemServicing {
  private nonisolated static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "App")

  /// Where `SMAppService.agent(plistName:)` finds the agent, in `Contents/Library/LaunchAgents`.
  private nonisolated static let agentPlist = "io.github.krisarmstrong.ferry.agent.plist"

  public init() {}

  public func registerAgent() async {
    await Task.detached(priority: .utility) {
      let agent = SMAppService.agent(plistName: Self.agentPlist)
      do {
        try agent.register()
      } catch {
        Self.log.error("registering the agent failed: \(error, privacy: .public)")
      }
      Self.log.info("agent status: \(Self.describe(agent.status), privacy: .public)")
    }.value
  }

  public func opensAtLogin() async -> Bool {
    await Task.detached(priority: .utility) {
      SMAppService.mainApp.status == .enabled
    }.value
  }

  public func setOpensAtLogin(_ enabled: Bool) async throws {
    try await Task.detached(priority: .utility) {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    }.value
  }

  public func unregisterAgent() async throws {
    try await Task.detached(priority: .utility) {
      try await SMAppService.agent(plistName: Self.agentPlist).unregister()
    }.value
  }

  public func open(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  public func reveal(_ urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  public func quit() {
    NSApplication.shared.terminate(nil)
  }

  private nonisolated static func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown (\(status.rawValue))"
    }
  }
}
