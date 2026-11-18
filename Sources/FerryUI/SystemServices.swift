import AppKit
import ServiceManagement
import os

/// The system calls `AppModel` makes outside the agent, behind a protocol so tests can check
/// their order with a fake.
@MainActor
public protocol SystemServicing {
  /// Whether Ferry opens at login.
  var opensAtLogin: Bool { get }
  func setOpensAtLogin(_ enabled: Bool) throws
  func unregisterAgent() async throws
  func open(_ url: URL)
  func quit()
}

/// `SMAppService`, `NSWorkspace` and `NSApplication`.
@MainActor
public final class SystemServices: SystemServicing {
  private static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "App")

  /// Where `SMAppService.agent(plistName:)` finds the agent, in `Contents/Library/LaunchAgents`.
  private static let agent = SMAppService.agent(
    plistName: "io.github.krisarmstrong.ferry.agent.plist")

  public init() {}

  /// Registers the agent, which launchd then starts on demand. Registering again is harmless.
  public func registerAgent() {
    do {
      try Self.agent.register()
    } catch {
      Self.log.error("registering the agent failed: \(error, privacy: .public)")
    }
    Self.log.info("agent status: \(Self.describe(Self.agent.status), privacy: .public)")
  }

  public var opensAtLogin: Bool {
    SMAppService.mainApp.status == .enabled
  }

  public func setOpensAtLogin(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  public func unregisterAgent() async throws {
    try await Self.agent.unregister()
  }

  public func open(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  public func quit() {
    NSApplication.shared.terminate(nil)
  }

  private static func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown (\(status.rawValue))"
    }
  }
}
