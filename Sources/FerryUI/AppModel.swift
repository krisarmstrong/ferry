import DeviceKit
import FerryIPC
import Foundation
import Observation
import os

/// The menu's state: the agent's device list, and the setup guide.
///
/// Nothing polls while the menu is closed. The menu calls `watchWhileMenuOpen()` from a task
/// that runs while it is open, which refreshes on open and then every 2 s until it closes, and
/// reads the expanded device's details at most every 10 s.
/// Actions refresh when they finish, and the app refreshes once at launch.
@Observable @MainActor public final class AppModel {
  /// Whether the agent answered the last status request.
  public enum AgentState: Sendable, Equatable {
    case checking
    case running
    /// The request failed, so the device list is not known.
    case unreachable
    /// The request failed and Ferry was updated while it ran: the new agent refuses this copy.
    case replaced
  }

  /// Where macOS turns on File Provider extensions.
  static let loginItemsSettings = URL(
    string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

  static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "AppModel")
  private static let pollInterval = Duration.seconds(2)
  static let emptyGuideDelay = Duration.seconds(10)
  /// After restarting an agent it could not reach, how many times the app asks it for its status,
  /// `recoveryPause` apart, before leaving it until the next outage.
  static let recoveryChecks = 5
  static let recoveryPause = Duration.seconds(1)

  public private(set) var devices: [AttachedDevice] = []
  /// Assumed on until the agent says otherwise, so the turn-on row does not flash at launch.
  public private(set) var provider = ProviderState.enabled
  public internal(set) var agent = AgentState.checking
  /// What macOS said about the helper the last time the agent did not answer.
  public private(set) var helper = HelperStatus.allowed
  /// Transfers the agent is running, as of the last status.
  public private(set) var transfers: [ActiveTransfer] = []
  /// Whether adb can be used; `nil` until the agent has looked.
  public internal(set) var adbStatus: ADBStatus?
  /// The agent cannot watch USB, so devices come and go in the menu only every 30 s.
  public private(set) var usbWatchFailed = false
  /// The number of each served device's session, as of the last status.
  private(set) var sessions: [DeviceID: UInt64] = [:]
  /// Devices with USB debugging on that wait for the user to allow this Mac on them.
  private(set) var awaitingUSBDebugging: Set<DeviceID> = []
  /// Network devices (`host:port`) waiting for the user to allow this Mac on them.
  public private(set) var awaitingAuthorization: [String] = []
  /// Devices the agent reconnects over the network.
  public private(set) var remembered: [RememberedDevice] = []
  /// The address adb serves each network device on now.
  private(set) var connectedAddresses: [DeviceID: WirelessEndpoint] = [:]
  /// New addresses for known devices, waiting for the user to say Use It or Ignore.
  public private(set) var unconfirmed: [UnconfirmedAddress] = []
  /// What the last network request said, for the menu's status row; `nil` once it connected. A
  /// form's failure stays in the form (`NetworkForm.message`).
  public internal(set) var wirelessMessage: MenuNotice?
  /// The network form open under the network rows, with what was typed in it.
  var networkForm: NetworkForm?
  /// The open form's request on its way, so collapsing the form can cancel it.
  @ObservationIgnored var networkSend: Task<WirelessReply, Never>?
  /// Set once the user opens a network form this run: a Wi-Fi-only user needs adb too.
  var wantsNetwork = false
  /// Ferry's own copy of adb, from Google's platform tools (see `AppModel+PlatformTools`).
  var platformTools = PlatformToolsState()
  /// The last failed action, shown until the next one succeeds.
  public internal(set) var actionError: MenuNotice?
  /// Screen recordings running, as of the last status.
  public private(set) var recordings: [ActiveRecording] = []
  /// Apps being installed from this menu, by device: the file's name and how much has reached
  /// the device.
  public internal(set) var installs: [DeviceID: AppInstall] = [:]
  /// The request sending each install, so Cancel can stop it.
  var installRequests: [DeviceID: Task<AgentResponse?, Never>] = [:]
  /// Recordings this menu asked for, by when, until the agent answers: shown before the status
  /// lists them.
  var requestedRecordings: [DeviceID: Date] = [:]
  /// Finished recordings being saved, so each is collected once.
  var collectingRecordings: Set<DeviceID> = []
  /// The collection a status started for each device, kept until the device is no longer listed
  /// with a recording: a caller (a test) can wait for it to end.
  @ObservationIgnored var backgroundCollections: [DeviceID: Task<Void, Never>] = [:]
  /// Finished recordings the app could not save, and why.
  var unsavedRecordings: [DeviceID: UnsavedRecording] = [:]
  /// Unsaved recordings whose capture folders are being checked, so each is checked once.
  var probingRecordings: Set<DeviceID> = []
  /// What the last tool request said when it succeeded without a file to show.
  public internal(set) var toolMessage: String?
  /// Where the system saved changes an eject removed before they reached the device. Shown until
  /// the next action.
  public internal(set) var preservedChanges: [URL] = []
  /// Hidden locations, their device away, whose changes wait to be sent (see `StatusReport`).
  private(set) var waitingToSend: [String] = []
  /// Which row of the menu is expanded (see `MenuExpansion`).
  var expansion = MenuExpansion()
  /// What each device said about itself, for its inline details (see `AppModel+Details`).
  var details: [DeviceID: DetailsRead] = [:]
  /// The read running for each device (one at most), so the menu can cancel it and a test can
  /// wait for it. No view reads it.
  @ObservationIgnored var detailReads: [DeviceID: DetailReadTask] = [:]
  /// The detail line just copied from, which shows "Copied" or "Copied All" for a moment.
  var copiedLine: CopiedLine?
  /// Each device's port forwards, kept while it is listed: the menu redraws its rows on every
  /// status, and the ports typed must outlive them (see `AppModel+Developer`).
  var forwardSessions: [DeviceID: PortForwardsSession] = [:]
  /// The device whose Port Forwarding disclosure is open, one at most.
  var forwardsOpen: DeviceID?
  /// Why Remove Ferry… failed, shown under it in Help; the menu's error row is for its own
  /// actions.
  public internal(set) var removalError: String?
  /// Read from the system once launched (see `launch()`) and each time the menu opens; off
  /// until then.
  public internal(set) var loginItem = LoginItemStatus.disabled
  /// Set by the app when the build can update itself; the menu shows Check for Updates… only
  /// then.
  public var updater: (any UpdateChecking)?
  /// The login item change being applied, how many have been requested, and how many applied.
  private var loginItemChange: Task<Void, Never>?
  /// The agent build launch restarted, recorded once that agent answers (see `startAgent()`).
  var restartedBuild: String?
  /// Set when the agent was restarted for this outage, or is being; cleared once it answers.
  var recoveryAttempted = false
  private var loginItemRequests = 0
  private var loginItemsApplied = 0

  /// The Open at Login checkmark: on, or registered and waiting for approval.
  public var opensAtLogin: Bool { loginItem != .disabled }

  /// The steps the guide shows; `nil` shows the model picker.
  public var guideFamily: DeviceFamily?
  public var guideTopic = GuideTopic.fileTransfer
  public var isGuidePresented = false
  /// Set with `isGuidePresented`, and cleared by the one view that brings the guide window
  /// forward, so reopening the menu does not pull the guide in front of it again.
  var guideOpenPending = false
  /// The message whose Help topic the Help window should open, until it takes it.
  var helpRequest: String?

  let client: any AgentSending
  let services: any SystemServicing
  let sleep: @Sendable (Duration) async throws -> Void
  let now: @Sendable () -> ContinuousClock.Instant
  /// Devices the guide has opened for this app run.
  private var guidedDevices: Set<DeviceID> = []
  var emptyGuideShown = false

  public convenience init(
    client: any AgentSending, services: any SystemServicing = SystemServices()
  ) {
    self.init(client: client, services: services, sleep: { try await Task.sleep(for: $0) })
  }

  init(
    client: any AgentSending, services: any SystemServicing,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
  ) {
    self.client = client
    self.services = services
    self.sleep = sleep
    self.now = now
  }

  public func refresh() async {
    if await readStatus() == .lost, agent == .unreachable { await recoverAgent() }
  }

  /// Asks the agent for its status and shows it.
  func readStatus() async -> StatusRead {
    do {
      switch try await client.send(.status, file: nil) {
      case .status(let report):
        apply(report)
        return .answered
      default:
        Self.log.error("agent answered status with something else")
        agent = .unreachable
        return .failed
      }
    } catch .cancelled {
      return .cancelled
    } catch {
      Self.log.error("status request failed: \(String(describing: error), privacy: .private)")
      agent = services.appWasReplaced() ? .replaced : .unreachable
      helper = await services.helperStatus()
      return error == .deviceDisconnected ? .lost : .failed
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
    var loginItemRead = false
    resetExpansion()
    while !Task.isCancelled {
      await refresh()
      // The menu may have closed while the status was read.
      guard !Task.isCancelled else { break }
      loadExpandedDetailsIfDue()
      // Once per opening, after the first status, so the devices never wait on macOS.
      if !loginItemRead {
        loginItemRead = true
        await readLoginItem()
      }
      if agent == .running, answeredFor == nil { answeredFor = .zero }
      if let answeredFor { considerEmptyGuide(openFor: answeredFor) }
      do {
        try await sleep(Self.pollInterval)
      } catch {
        break
      }
      answeredFor? += Self.pollInterval
    }
    cancelDetailReads()
  }

  public func turnOnInFinder() {
    services.open(Self.loginItemsSettings)
  }

  /// Where the user allows Ferry's helper to run in the background.
  public func openLoginItems() {
    services.open(Self.loginItemsSettings)
  }

  /// The Open at Login row: shows `enabled` at once, then applies it after any change still
  /// being applied, so quick toggles reach macOS in order and the switch never snaps back
  /// meanwhile. Once the last change is applied, it shows what macOS reports.
  public func requestOpensAtLogin(_ enabled: Bool) {
    loginItem = enabled ? .enabled : .disabled
    loginItemRequests += 1
    let request = loginItemRequests
    let previous = loginItemChange
    loginItemChange = Task {
      await previous?.value
      await applyOpensAtLogin(enabled, request: request)
    }
  }

  /// Reads what macOS has now, as the menu opens: the user may have changed it in System
  /// Settings. While a change is being applied the switch keeps the value chosen.
  func readLoginItem() async {
    let request = loginItemRequests
    guard loginItemsApplied == request else { return }
    let read = await services.loginItemStatus()
    if loginItemRequests == request, loginItemsApplied == request { loginItem = read }
  }

  /// Returns once every requested login item change is applied.
  func loginItemSettled() async {
    await loginItemChange?.value
  }

  private func applyOpensAtLogin(_ enabled: Bool, request: Int) async {
    do {
      try await services.setOpensAtLogin(enabled)
      actionError = nil
    } catch {
      Self.log.error("open at login: \(error, privacy: .public)")
      actionError = MenuNotice(
        LocalizedStringResource("Could not change Open at Login.", bundle: .module))
    }
    let reported = await services.loginItemStatus()
    loginItemsApplied = request
    // A later request shows its own value until it is applied in turn.
    if request == loginItemRequests { loginItem = reported }
  }

  func perform(_ request: AgentRequest) async {
    if request != .recheckADB { preservedChanges = [] }
    toolMessage = nil
    do {
      switch try await client.send(request, file: nil) {
      case .done:
        actionError = nil
      case .removed(let preserved):
        actionError = nil
        preservedChanges = preserved.filter(Self.holdsSomething)
      case .failure(let error):
        actionError = DevicePresentation.notice(for: error)
      default:
        actionError = DevicePresentation.notice(for: .io("unexpected reply"))
      }
    } catch {
      actionError = DevicePresentation.notice(for: error)
    }
    await refresh()
  }

  private func apply(_ report: StatusReport) {
    let devices = report.devices
    self.devices = devices
    helper = .allowed
    recoveryAttempted = false
    if let build = restartedBuild {
      services.recordStartedAgent(build)
      restartedBuild = nil
    }
    provider = report.provider
    transfers = report.transfers
    noteADBStatus(report.adbStatus)
    usbWatchFailed = report.usbWatchFailed
    sessions = report.sessions
    awaitingUSBDebugging = Set(report.awaitingUSBDebugging)
    awaitingAuthorization = report.awaitingAuthorization
    remembered = report.remembered
    connectedAddresses = report.connectedAddresses
    waitingToSend = report.waitingToSend
    unconfirmed = report.unconfirmed
    recordings = report.recordings
    collectFinishedRecordings()
    updateExpansion()
    forgetDetailsOfGoneDevices()
    forgetForwardsOfGoneDevices()
    agent = .running
    let states = devices.map { "\(DevicePresentation.kind(of: $0.state))/\($0.method.rawValue)" }
      .joined(separator: ",")
    let adb = report.adbStatus.map { String(describing: $0) } ?? "unknown"
    Self.log.info(
      """
      devices: [\(states, privacy: .public)] \
      provider: \(report.provider.rawValue, privacy: .public) adb: \(adb, privacy: .public)
      """)
    for device in devices where DevicePresentation.needsFileTransferSteps(device) {
      guard guidedDevices.insert(device.id).inserted, !isGuidePresented else { continue }
      showGuide(for: device)
    }
  }
}

extension AppModel {
  /// An ejected device reports `.ejected`, which never opens the guide.
  public func eject(_ id: DeviceID) async {
    await perform(.eject(id))
  }

  /// Mounts an ejected device again.
  public func mount(_ id: DeviceID) async {
    await perform(.recheck(id))
  }

  /// Asks the agent to open a device again, after the app holding it quits.
  public func recheck(_ id: DeviceID) async {
    await perform(.recheck(id))
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
}
