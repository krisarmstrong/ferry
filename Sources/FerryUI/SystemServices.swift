import AppKit
import Darwin
import PlatformTools
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

/// Whether Ferry opens at login, as macOS has it.
public enum LoginItemStatus: Sendable, Equatable {
  case disabled
  case enabled
  /// Registered, but waiting for the user to allow it in Login Items & Extensions.
  case needsApproval
}

/// The system calls `AppModel` makes outside the agent, behind a protocol so tests can check
/// their order with a fake.
@MainActor
public protocol SystemServicing {
  /// Registers the agent, which launchd then starts on demand. Registering again is harmless.
  func registerAgent() async
  /// The agent executable in the bundle, by its code directory hash; `nil` if unreadable.
  func agentBuild() -> String?
  /// The agent `recordStartedAgent` last recorded.
  func startedAgentBuild() -> String?
  func recordStartedAgent(_ build: String)
  /// Stops the running agent, which removes its launchd job, and registers the one in the
  /// bundle. False if the new agent could not be registered.
  func restartAgent() async -> Bool
  /// Has Launch Services read the app and each extension in it again, so macOS uses the ones in
  /// this bundle: after a manual reinstall it can forget the File Provider extension for minutes
  /// (error -2001). Harmless when nothing changed.
  func registerExtensions() async
  /// What macOS says about the helper now.
  func helperStatus() async -> HelperStatus
  /// Whether macOS has the agent registered and enabled (`SMAppService.Status.enabled`), whether
  /// or not launchd manages to start it.
  func agentIsEnabled() async -> Bool
  /// Whether Ferry opens at login.
  func loginItemStatus() async -> LoginItemStatus
  func setOpensAtLogin(_ enabled: Bool) async throws
  func unregisterAgent() async throws
  /// Deletes the agent's own folder (remembered devices, item tables, the adb server record),
  /// once it is unregistered and has exited, so no last save re-creates it.
  func removeAgentData() async throws
  func open(_ url: URL)
  /// Shows the items in Finder.
  func reveal(_ urls: [URL])
  func quit()
  /// Whether Ferry's executable on disk is no longer the one this process launched from: the
  /// app was updated while it ran.
  func appWasReplaced() -> Bool
  /// Opens Ferry again from its bundle and quits this copy.
  func relaunch()
  /// Puts `text` on the pasteboard.
  func copy(_ text: String)
  /// Has VoiceOver say `text`, for a change away from its focus.
  func announce(_ text: String)
  /// Asks the user for an `.apk`; `nil` if they cancel.
  func chooseAPK() async -> URL?
  /// Asks the user for files to send to a device; empty if they cancel.
  func chooseFilesToSend() async -> [URL]
  /// The folders screenshots and recordings go under, in order of preference, each holding a
  /// folder per device. Touches no disk.
  func captureFolders() -> [URL]
  /// Asks the user for a folder to save in; `nil` if they cancel.
  func chooseFolder() async -> URL?
  /// Asks the user where to save a log (plain text); `nil` if they cancel.
  func chooseLogDestination(suggestedName: String) async -> URL?
  /// Opens the `.command` file in Terminal, which runs it. False if Terminal could not.
  func openInTerminal(_ script: URL) async -> Bool
  /// The Android SDK License acceptance recorded in Ferry's defaults.
  func platformToolsAcceptance() -> LicenseAcceptance?
  func recordPlatformToolsAcceptance(_ acceptance: LicenseAcceptance)
  /// The version of the platform tools Ferry fetched and would use, if any.
  func fetchedPlatformToolsVersion() -> String?
  /// Fetches the pinned platform tools (see `PlatformToolsFetcher`).
  func fetchPlatformTools(accepted: LicenseAcceptance?) async throws(PlatformToolsError)
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

  /// The app's executable and its bundle's seal, and which files they were at launch.
  private let bundleFiles = [
    Bundle.main.executableURL,
    Bundle.main.bundleURL.appending(path: "Contents/_CodeSignature/CodeResources"),
  ].compactMap { $0 }
  private let launchedFrom: BundleFingerprint

  public init() {
    launchedFrom = BundleFingerprint(of: bundleFiles)
  }

  public func registerAgent() async {
    await Task.detached(priority: .utility) {
      let agent = SMAppService.agent(plistName: Self.agentPlist)
      do {
        try agent.register()
      } catch {
        Self.log.error("registering the agent failed: \(error, privacy: .private)")
      }
      Self.log.info("agent status: \(Self.describe(agent.status), privacy: .public)")
    }.value
  }

  /// Where `recordStartedAgent` keeps the agent last started.
  private nonisolated static let startedAgentKey = "StartedAgentBuild"

  public func agentBuild() -> String? {
    let agent = Bundle.main.bundleURL.appending(path: "Contents/MacOS/FerryAgent")
    var code: SecStaticCode?
    var information: CFDictionary?
    guard SecStaticCodeCreateWithPath(agent as CFURL, [], &code) == errSecSuccess, let code,
      SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
      let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    else { return nil }
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  public func startedAgentBuild() -> String? {
    UserDefaults.standard.string(forKey: Self.startedAgentKey)
  }

  public func recordStartedAgent(_ build: String) {
    UserDefaults.standard.set(build, forKey: Self.startedAgentKey)
  }

  public func restartAgent() async -> Bool {
    await Task.detached(priority: .utility) {
      let agent = SMAppService.agent(plistName: Self.agentPlist)
      // Waits until launchd has stopped the old agent. Not registered (a first launch) is fine.
      do {
        try await agent.unregister()
      } catch {
        Self.log.info("unregistering the agent to restart it: \(error, privacy: .private)")
      }
      let registered: Bool
      do {
        try agent.register()
        registered = true
      } catch {
        Self.log.error("registering the agent failed: \(error, privacy: .private)")
        registered = false
      }
      Self.log.info("agent restarted, status: \(Self.describe(agent.status), privacy: .public)")
      return registered
    }.value
  }

  /// Not a copy that will go away: one macOS translocated, or one on a read-only volume such as a
  /// mounted disk image. Registered, it would be the copy macOS uses, and the installed one would
  /// lose its extensions once it went.
  nonisolated static func registersExtensions(of bundle: URL, onReadOnlyVolume: Bool) -> Bool {
    !onReadOnlyVolume && !bundle.path.contains("/AppTranslocation/")
  }

  public func registerExtensions() async {
    let bundle = Bundle.main.bundleURL
    let plugIns = Bundle.main.builtInPlugInsURL
    await Task.detached(priority: .utility) {
      let readOnly =
        (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
      guard Self.registersExtensions(of: bundle, onReadOnlyVolume: readOnly) else {
        Self.log.info("not registering a translocated or read-only copy with Launch Services")
        return
      }
      let extensions =
        plugIns.flatMap {
          try? FileManager.default.contentsOfDirectory(
            at: $0, includingPropertiesForKeys: nil)
        }?.filter { $0.pathExtension == "appex" } ?? []
      for url in [bundle] + extensions {
        let status = LSRegisterURL(url as CFURL, true)
        if status != noErr {
          let name = url.lastPathComponent
          Self.log.error(
            "registering \(name, privacy: .public) failed: \(status, privacy: .public)")
        }
      }
    }.value
  }

  public func agentIsEnabled() async -> Bool {
    await Task.detached(priority: .utility) {
      SMAppService.agent(plistName: Self.agentPlist).status == .enabled
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

  public func loginItemStatus() async -> LoginItemStatus {
    await Task.detached(priority: .utility) {
      switch SMAppService.mainApp.status {
      case .enabled: .enabled
      case .requiresApproval: .needsApproval
      default: .disabled
      }
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

  public func removeAgentData() async throws {
    // Unregistering stops the agent, but it may still be saving: up to 5 s for it to exit.
    let agent = Bundle.main.bundleURL.appending(path: "Contents/MacOS/FerryAgent")
      .resolvingSymlinksInPath().path
    let deadline = ContinuousClock.now + .seconds(5)
    while Self.isRunning(agent), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let folder = support.appending(path: "io.github.krisarmstrong.ferry.agent")
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    try FileManager.default.removeItem(at: folder)
  }

  /// Whether a process of this user runs the program at `path`.
  private static func isRunning(_ path: String) -> Bool {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return false }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard listed > 0 else { return false }
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
    return pids.prefix(Int(listed)).contains { pid in
      let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
      return length > 0 && String(bytes: buffer.prefix(Int(length)), encoding: .utf8) == path
    }
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

  public func appWasReplaced() -> Bool {
    BundleFingerprint(of: bundleFiles) != launchedFrom
  }

  /// Opens a new instance from the bundle, which runs the updated code, then quits this one.
  /// If the new one cannot open, this one stays, so the menu is not lost.
  public func relaunch() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    let bundle = Bundle.main.bundleURL
    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
      Task { @MainActor in
        if let error {
          Self.log.error("relaunching failed: \(error, privacy: .private)")
        } else {
          NSApplication.shared.terminate(nil)
        }
      }
    }
  }

  public func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  public func announce(_ text: String) {
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
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

  public func chooseFilesToSend() async -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.message = String(
      localized: LocalizedStringResource(
        "Choose files to send to the device’s Download folder.", bundle: .module))
    panel.prompt = String(localized: LocalizedStringResource("Send", bundle: .module))
    NSApp.activate()
    return panel.runModal() == .OK ? panel.urls : []
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
      Self.log.error("opening Terminal failed: \(error, privacy: .private)")
      return false
    }
  }

  public func captureFolders() -> [URL] {
    [CaptureFiles.documentsRoot()]
  }

  public func platformToolsAcceptance() -> LicenseAcceptance? {
    LicenseAcceptance.recorded(in: .standard)
  }

  public func recordPlatformToolsAcceptance(_ acceptance: LicenseAcceptance) {
    acceptance.record(in: .standard)
  }

  public func fetchedPlatformToolsVersion() -> String? {
    PlatformToolsFolder.standard.installedADB(pinned: PlatformToolsRelease.pinned.version)?
      .deletingLastPathComponent().lastPathComponent
  }

  /// Downloads, checks and extracts off the main actor.
  public func fetchPlatformTools(accepted: LicenseAcceptance?) async throws(PlatformToolsError) {
    _ = try await PlatformToolsFetcher().fetch(accepted: accepted)
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
