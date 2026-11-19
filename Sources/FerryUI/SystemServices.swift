import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import os

/// Whether macOS lets Ferry's helper (the agent) run.
public enum HelperStatus: Sendable, Equatable {
  /// Registered and allowed; launchd starts it on demand.
  case allowed
  /// Turned off under Allow in the Background in Login Items & Extensions.
  case requiresApproval
  /// macOS cannot find the helper in Ferry's bundle.
  case notFound
}

/// The system calls `AppModel` makes outside the agent, behind a protocol so tests can check
/// their order with a fake.
@MainActor
public protocol SystemServicing {
  /// Registers the agent, which launchd then starts on demand. Registering again is harmless.
  func registerAgent() async
  /// What macOS says about the helper now.
  func helperStatus() async -> HelperStatus
  /// Whether Ferry opens at login.
  func opensAtLogin() async -> Bool
  func setOpensAtLogin(_ enabled: Bool) async throws
  func unregisterAgent() async throws
  func open(_ url: URL)
  /// Shows the items in Finder.
  func reveal(_ urls: [URL])
  func quit()
  /// Puts `text` on the pasteboard.
  func copy(_ text: String)
  /// Asks the user for an `.apk`; `nil` if they cancel.
  func chooseAPK() async -> URL?
  /// Where screenshots and recordings go, in order of preference: where macOS saves its own,
  /// then the Desktop.
  func captureFolders() -> [URL]
  /// Asks the user for a folder to save in; `nil` if they cancel.
  func chooseFolder() async -> URL?
  /// Asks the user where to save a log (plain text); `nil` if they cancel.
  func chooseLogDestination(suggestedName: String) async -> URL?
  /// Opens the `.command` file in Terminal, which runs it. False if Terminal could not.
  func openInTerminal(_ script: URL) async -> Bool
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

  public func helperStatus() async -> HelperStatus {
    await Task.detached(priority: .utility) {
      switch SMAppService.agent(plistName: Self.agentPlist).status {
      case .requiresApproval: .requiresApproval
      case .notFound: .notFound
      // Not registered yet is registered at launch; anything else, the agent's own failure.
      default: .allowed
      }
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

  public func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  public func chooseAPK() async -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = String(
      localized: LocalizedStringResource(
        "Choose an Android app (.apk) to install.", bundle: .module))
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
  }

  public func chooseFolder() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
  }

  public func chooseLogDestination(suggestedName: String) async -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.allowedContentTypes = [.plainText]
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
  }

  public func openInTerminal(_ script: URL) async -> Bool {
    guard
      let terminal = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.Terminal")
    else { return false }
    do {
      _ = try await NSWorkspace.shared.open(
        [script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
      return true
    } catch {
      Self.log.error("opening Terminal failed: \(error, privacy: .public)")
      return false
    }
  }

  public func captureFolders() -> [URL] {
    [CaptureFiles.current(), CaptureFiles.desktop()]
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
