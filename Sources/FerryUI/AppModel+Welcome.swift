import DeviceKit
import Foundation

/// The welcome: on a Mac new to Ferry it opens once, after the agent's first answer, with the
/// steps still needed, and follows the status while it is open. Completed or closed, it never
/// opens by itself again; Help opens it on request. A Mac that ran Ferry before, or one where
/// everything is already in place, never sees it.
///
/// The Local Network note is the same kind of thing for Wi-Fi: said once, the first time the
/// user reaches for it, since macOS asks then and Ferry cannot read the answer.
extension AppModel {
  /// The Help topic the Local Network note links to.
  nonisolated static let localNetworkHelpTopic = "use-over-wifi"

  public var isWelcomePresented: Bool { welcome.isPresented }

  /// A device is ready and Ferry is on in Finder.
  public var isWelcomeComplete: Bool { welcome.check?.isComplete == true }

  /// The steps the window lists, in order, each ticked once done. Empty until the agent answers.
  var welcomeSteps: [WelcomeStepLine] {
    guard let check = welcome.check else { return [] }
    return WelcomeStep.allCases.filter(welcome.listed.contains).map {
      WelcomeStepLine(step: $0, isDone: !check.needed.contains($0))
    }
  }

  /// Called by `launch()` before the agent starts: no agent ever started means Ferry is new on
  /// this Mac.
  func noteFirstRun() {
    welcome.isFirstRun = services.startedAgentBuild() == nil
  }

  /// Opens the window, from Help or on the first run, listing what is needed and what is done.
  public func showWelcome() {
    let check = currentWelcomeCheck
    welcome.check = check
    welcome.listed = check.map { $0.needed.union($0.done) } ?? []
    welcome.isPresented = true
    welcome.openPending = true
  }

  /// Not Now, Done or the close button: it is finished, and never opens by itself again.
  public func welcomeClosed() {
    welcome.isPresented = false
    welcome.openPending = false
    services.recordMark(.welcomeFinished)
  }

  /// Whether the welcome window should be brought forward now. True once per `showWelcome()`.
  func takeWelcomeOpenRequest() -> Bool {
    defer { welcome.openPending = false }
    return welcome.openPending
  }

  /// The Connect a device step's guide: on the device attached if there is one, else the model
  /// picker.
  public func showWelcomeGuide(topic: GuideTopic) {
    let device = devices.first { DevicePresentation.needsFileTransferSteps($0) } ?? devices.first
    showGuide(
      family: device.flatMap { GuideSteps.family(forModel: $0.info.model) }, topic: topic)
  }

  /// Refreshes now and every 2 s while the window is open, so its steps follow the device and
  /// System Settings, until the calling task is cancelled.
  public func watchWhileWelcomeOpen() async {
    while !Task.isCancelled {
      await refresh()
      do {
        try await sleep(Self.pollInterval)
      } catch {
        break
      }
    }
  }

  /// After each status: the first answer decides whether the welcome opens; while it is open,
  /// steps that turn up are listed; and once the setup is complete it is recorded.
  func considerWelcome() {
    guard let check = currentWelcomeCheck else { return }
    if !welcome.decided {
      welcome.decided = true
      decideWelcome(check)
      return
    }
    guard welcome.isPresented else { return }
    welcome.check = check
    welcome.listed.formUnion(check.needed)
    if check.isComplete { services.recordMark(.welcomeFinished) }
  }

  private func decideWelcome(_ check: WelcomeCheck) {
    guard !services.hasMark(.welcomeFinished) else { return }
    guard welcome.isFirstRun, !check.isComplete else {
      services.recordMark(.welcomeFinished)
      return
    }
    showWelcome()
  }

  private var currentWelcomeCheck: WelcomeCheck? {
    WelcomeCheck(agent: agent, provider: provider, devices: devices, adbStatus: adbStatus)
  }

  /// While the welcome is open, or about to be, it carries the guide's help: the guide does not
  /// open by itself as well.
  var welcomeHoldsGuide: Bool {
    welcome.isPresented || (welcome.isFirstRun && !welcome.decided)
  }

  /// The user reached for Wi-Fi: the first time ever, the menu says macOS will ask. A Mac with a
  /// remembered device has reached one over the network, so macOS has asked already: recorded,
  /// not said.
  func noteWiFiUse() {
    guard !services.hasMark(.localNetworkExplained) else { return }
    services.recordMark(.localNetworkExplained)
    showsLocalNetworkNote = remembered.isEmpty
  }

  /// The note's OK.
  public func dismissLocalNetworkNote() {
    showsLocalNetworkNote = false
  }
}
