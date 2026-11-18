import DeviceKit
import FerryIPC
import Foundation
import Observation
import os

/// The menu's state: the agent's device list, and the setup guide.
///
/// Nothing polls while the menu is closed. The menu calls `watchWhileMenuOpen()` from a task
/// that runs while it is open, which refreshes on open and then every 2 s until it closes.
/// Actions refresh when they finish, and the app refreshes once at launch.
@Observable @MainActor public final class AppModel {
  /// Whether the agent answered the last status request.
  public enum AgentState: Sendable, Equatable {
    case checking
    case running
    /// The request failed, so the device list is not known.
    case unreachable
  }

  /// Where macOS turns on File Provider extensions.
  static let loginItemsSettings = URL(
    string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

  private static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "AppModel")
  private static let pollInterval = Duration.seconds(2)
  private static let emptyGuideDelay = Duration.seconds(10)

  public private(set) var devices: [AttachedDevice] = []
  /// Assumed on until the agent says otherwise, so the turn-on row does not flash at launch.
  public private(set) var provider = ProviderState.enabled
  public private(set) var agent = AgentState.checking
  /// What macOS said about the helper the last time the agent did not answer.
  public private(set) var helper = HelperStatus.allowed
  /// Transfers the agent is running, as of the last status.
  public private(set) var transfers: [ActiveTransfer] = []
  /// The last failed action, shown until the next one succeeds. It can carry device-supplied
  /// detail, so it is shown verbatim, never parsed as Markdown.
  public private(set) var actionError: String?
  /// Where the system saved changes an eject removed before they reached the device. Shown until
  /// the next action.
  public private(set) var preservedChanges: [URL] = []
  /// Read from the system once launched (see `launch()`); `false` until then.
  public private(set) var opensAtLogin = false

  /// The steps the guide shows; `nil` shows the model picker.
  public var guideFamily: DeviceFamily?
  public var isGuidePresented = false
  /// Set with `isGuidePresented`, and cleared by the one view that brings the guide window
  /// forward, so reopening the menu does not pull the guide in front of it again.
  private(set) var guideOpenPending = false

  private let client: any AgentSending
  private let services: any SystemServicing
  private let sleep: @Sendable (Duration) async throws -> Void
  /// Devices the guide has opened for this app run.
  private var guidedDevices: Set<DeviceID> = []
  private var emptyGuideShown = false

  public convenience init(
    client: any AgentSending, services: any SystemServicing = SystemServices()
  ) {
    self.init(client: client, services: services, sleep: { try await Task.sleep(for: $0) })
  }

  init(
    client: any AgentSending, services: any SystemServicing,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.client = client
    self.services = services
    self.sleep = sleep
  }

  /// The transfers running on `device`.
  public func transfers(on device: DeviceID) -> [ActiveTransfer] {
    transfers.filter { $0.device == device }
  }

  /// No answer from the agent yet, so whether a device is attached is not known.
  public var isChecking: Bool { agent == .checking }

  /// Ferry's locations exist and are all off in Finder: not an error, but the user must turn
  /// Ferry on. With no location yet there is nothing to turn on.
  public var showsTurnOnRow: Bool {
    agent == .running && provider == .disabled
  }

  public func refresh() async {
    do {
      switch try await client.send(.status, file: nil) {
      case .status(let report):
        apply(report)
      default:
        Self.log.error("agent answered status with something else")
        agent = .unreachable
      }
    } catch {
      Self.log.error("status request failed: \(String(describing: error), privacy: .private)")
      agent = .unreachable
      helper = await services.helperStatus()
    }
  }

  /// The menu's Refresh: asks the agent to list each ready device's folders again, so changes
  /// made on the device reach Finder, and to try again every device it is not using (one not
  /// sharing files, one ejected), then reads the status.
  public func refreshDevices() async {
    for device in devices {
      let request: AgentRequest
      switch device.state {
      case .ready:
        request = .refresh(device.id)
      case .notSharingFiles, .ejected:
        request = .recheck(device.id)
      default:
        continue
      }
      do {
        _ = try await client.send(request, file: nil)
      } catch {
        Self.log.error("refresh failed: \(String(describing: error), privacy: .private)")
      }
    }
    await refresh()
  }

  /// Refreshes now and every 2 s until the calling task is cancelled, which happens when the
  /// menu closes.
  public func watchWhileMenuOpen() async {
    // How long the menu has been open since the agent first answered.
    var answeredFor: Duration?
    while !Task.isCancelled {
      await refresh()
      if agent == .running, answeredFor == nil { answeredFor = .zero }
      if let answeredFor { considerEmptyGuide(openFor: answeredFor) }
      do {
        try await sleep(Self.pollInterval)
      } catch {
        return
      }
      answeredFor? += Self.pollInterval
    }
  }

  /// Opens the guide, with the model picker, once per app run when the agent is running but
  /// has seen no device for 10 s of the menu being open, counted from the agent's first
  /// answer.
  func considerEmptyGuide(openFor: Duration) {
    guard agent == .running, devices.isEmpty, openFor >= Self.emptyGuideDelay,
      !emptyGuideShown
    else { return }
    emptyGuideShown = true
    showGuide(for: nil)
  }

  /// Opens the guide with the device's steps, or the model picker if Ferry does not know its
  /// model or no device is given.
  public func showGuide(for device: AttachedDevice?) {
    showGuide(family: device.flatMap { GuideSteps.family(forModel: $0.info.model) })
  }

  /// Opens the guide with the family's steps, or the model picker for `nil`.
  public func showGuide(family: DeviceFamily?) {
    guideFamily = family
    isGuidePresented = true
    guideOpenPending = true
  }

  /// Whether the guide window should be brought forward now. True once per `showGuide`.
  func takeGuideOpenRequest() -> Bool {
    defer { guideOpenPending = false }
    return guideOpenPending
  }

  /// An ejected device reports `.ejected`, which never opens the guide.
  public func eject(_ id: DeviceID) async {
    await perform(.eject(id))
  }

  /// Whether a location the system saved unsent changes to has anything in it: it can name a
  /// folder it left empty, or one already gone.
  static func holdsSomething(_ location: URL) -> Bool {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isFolder) else {
      return false
    }
    guard isFolder.boolValue else { return true }
    let contents = try? FileManager.default.contentsOfDirectory(atPath: location.path)
    return !(contents ?? []).isEmpty
  }

  public func revealPreservedChanges() {
    services.reveal(preservedChanges)
  }

  /// Mounts an ejected device again.
  public func mount(_ id: DeviceID) async {
    await perform(.recheck(id))
  }

  /// Asks the agent to open a device again, after the app holding it quits.
  public func recheck(_ id: DeviceID) async {
    await perform(.recheck(id))
  }

  public func turnOnInFinder() {
    services.open(Self.loginItemsSettings)
  }

  /// Where the user allows Ferry's helper to run in the background.
  public func openLoginItems() {
    services.open(Self.loginItemsSettings)
  }

  /// Registers the agent, reads its status, then whether Ferry opens at login. The system calls
  /// run off the main actor (see `SystemServices`), so the app opens without waiting on them.
  public func launch() async {
    await services.registerAgent()
    await refresh()
    opensAtLogin = await services.opensAtLogin()
  }

  public func setOpensAtLogin(_ enabled: Bool) async {
    do {
      try await services.setOpensAtLogin(enabled)
      actionError = nil
    } catch {
      Self.log.error("open at login: \(error, privacy: .public)")
      actionError = String(
        localized: LocalizedStringResource("Could not change Open at login.", bundle: .module))
    }
    opensAtLogin = await services.opensAtLogin()
  }

  /// Removes Ferry's locations from Finder, unregisters the agent and the login item, and
  /// quits. Stops if the locations or the agent remain, so the user can try again rather than
  /// being left with locations no agent serves. Once the agent is gone a retry could only fail,
  /// so a login item that will not unregister is logged and Ferry quits anyway. Changes the
  /// locations had not sent to a device are shown in Finder, since the menu goes away.
  public func removeFerry() async {
    let preserved: [URL]
    do {
      guard case .removed(let saved) = try await client.send(.removeAllDomains, file: nil) else {
        throw TransportError.io("agent kept its locations")
      }
      try await services.unregisterAgent()
      preserved = saved.filter(Self.holdsSomething)
    } catch {
      Self.log.error("removing Ferry failed: \(String(describing: error), privacy: .private)")
      actionError = String(
        localized: LocalizedStringResource(
          "Could not remove Ferry. Make sure Ferry is running, then try again.", bundle: .module))
      return
    }
    if !preserved.isEmpty {
      services.reveal(preserved)
    }
    if await services.opensAtLogin() {
      do {
        try await services.setOpensAtLogin(false)
      } catch {
        Self.log.error("removing the login item failed: \(error, privacy: .public)")
      }
    }
    services.quit()
  }

  private func perform(_ request: AgentRequest) async {
    preservedChanges = []
    do {
      switch try await client.send(request, file: nil) {
      case .done:
        actionError = nil
      case .removed(let preserved):
        actionError = nil
        preservedChanges = preserved.filter(Self.holdsSomething)
      case .failure(let error):
        actionError = DevicePresentation.message(for: error)
      default:
        actionError = DevicePresentation.message(for: .io("unexpected reply"))
      }
    } catch {
      actionError = DevicePresentation.message(for: error)
    }
    await refresh()
  }

  private func apply(_ report: StatusReport) {
    let devices = report.devices
    self.devices = devices
    helper = .allowed
    provider = report.provider
    transfers = report.transfers
    agent = .running
    let states = devices.map { DevicePresentation.kind(of: $0.state) }.joined(separator: ",")
    Self.log.info(
      "devices: [\(states, privacy: .public)] provider: \(report.provider.rawValue, privacy: .public)"
    )
    for device in devices where device.state == .notSharingFiles {
      guard guidedDevices.insert(device.id).inserted, !isGuidePresented else { continue }
      showGuide(for: device)
    }
  }
}
